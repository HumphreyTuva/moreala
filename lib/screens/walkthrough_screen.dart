import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/walkthrough_models.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../widgets/directional_nav_arrows.dart';
import '../widgets/pin_marker.dart';
import 'pin_hud_panel.dart';
import 'capture_screen.dart';

/// The core Matterport-style walkthrough screen.
///
/// Fixes the "abrupt cut / black screen / spinner" issue flagged in
/// ECO-02: rather than kicking off a fresh network fetch the moment
/// the student taps an arrow, every neighboring stop's image is
/// pre-fetched into local disk cache the moment the student ARRIVES
/// at a stop — while they're looking at it, not after they've already
/// tapped to leave. By the time they tap forward/back, the target
/// image is (usually) already on disk, so AnimatedSwitcher can
/// perform a real crossfade between two already-loaded images instead
/// of fading around a loading spinner.
///
/// First-ever visit to a stop (nothing pre-fetched yet) still shows a
/// brief loading state — unavoidable without the file already
/// existing, but it should be the rare case, not the norm.
///
/// Double-tap zoom: the first double-tap zooms in toward the tapped
/// point and stays zoomed; a second double-tap advances to the next
/// stop. Works on every photo, including the first stop.
class WalkthroughScreen extends StatefulWidget {
  final String modelId;
  const WalkthroughScreen({super.key, required this.modelId});

  @override
  State<WalkthroughScreen> createState() => _WalkthroughScreenState();
}

class _WalkthroughScreenState extends State<WalkthroughScreen>
    with SingleTickerProviderStateMixin {
  final _supabase = SupabaseService();
  final _cache = LocalCacheService();

  List<PhotoPoint> _points = [];
  int _currentIndex = 0;
  LookDirection _direction = LookDirection.forward;
  List<SpatialPin> _pins = [];
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;

  // cacheKey ("<photoPointId>_<direction>") -> resolved local File,
  // once downloaded. Looked up directly on build; if the key isn't
  // here yet, a lightweight loading state shows instead while
  // _resolveAndCache fetches it in the background.
  final Map<String, File> _resolvedFiles = {};

  // Double-tap zoom state. First double-tap zooms in toward the tapped
  // point and stays zoomed; a second double-tap advances to the next
  // stop (or zooms back out if there is no next stop).
  static const double _maxZoom = 2.5;
  late final AnimationController _zoomController;
  Alignment _tapAlignment = Alignment.center;
  Offset _doubleTapPosition = Offset.zero;
  bool _zoomedIn = false;

  @override
  void initState() {
    super.initState();
    _zoomController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _load();
  }

  @override
  void dispose() {
    _zoomController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final points = await _supabase.getPhotoPoints(widget.modelId);
    setState(() {
      _points = points;
      _loading = false;
    });
    if (points.isNotEmpty) {
      _loadPinsForCurrent();
      _loadBranchesForCurrent();
      _prefetchCurrentAndNeighbors();
    }
  }

  Future<void> _loadPinsForCurrent() async {
    final pins = await _supabase.getPinsForPhotoPoint(_points[_currentIndex].id);
    if (mounted) setState(() => _pins = pins);
  }

  Future<void> _loadBranchesForCurrent() async {
    final branches = await _supabase.getBranchLinksFrom(_points[_currentIndex].id);
    if (mounted) setState(() => _branches = branches);
  }

  PhotoPoint get _current => _points[_currentIndex];

  double get _zoomScale =>
      1.0 + Curves.easeOut.transform(_zoomController.value) * (_maxZoom - 1.0);

  void _resetZoom() {
    _zoomController.stop();
    _zoomController.value = 0;
    _zoomedIn = false;
  }

  String _cacheKeyFor(PhotoPoint point, LookDirection dir) => '${point.id}_${dir.name}';

  Future<String> _fetchSignedUrlFor(PhotoPoint point, LookDirection dir) async {
    final response = await Supabase.instance.client.functions.invoke(
      'r2-signed-url',
      body: {'object_key': point.urlFor(dir)},
    );
    final url = response.data?['url'] as String?;
    if (url == null) {
      throw Exception('r2-signed-url returned no url (status ${response.status})');
    }
    return url;
  }

  Future<void> _resolveAndCache(PhotoPoint point, LookDirection dir) async {
    final key = _cacheKeyFor(point, dir);
    if (_resolvedFiles.containsKey(key)) return; // already have it
    try {
      final file = await _cache.getOrDownload(
        modelId: widget.modelId,
        cacheKey: key,
        fetchSignedUrl: () => _fetchSignedUrlFor(point, dir),
      );
      if (mounted) setState(() => _resolvedFiles[key] = file);
    } catch (_) {
      // Leave unresolved — the loading placeholder stays up and a
      // retry happens naturally next time this stop/direction is
      // requested.
    }
  }

  /// Fires off (without blocking) downloads for the current stop's
  /// three directions AND the forward image of whichever stops are
  /// reachable from here — next/prev on the main line, plus any
  /// branch destinations. This is what makes the NEXT navigation feel
  /// instant.
  void _prefetchCurrentAndNeighbors() {
    final current = _current;
    _resolveAndCache(current, LookDirection.forward);
    _resolveAndCache(current, LookDirection.left);
    _resolveAndCache(current, LookDirection.right);

    void prefetchNeighbor(String? neighborId) {
      if (neighborId == null) return;
      final neighbor = _points.where((p) => p.id == neighborId).firstOrNull;
      if (neighbor != null) _resolveAndCache(neighbor, LookDirection.forward);
    }

    prefetchNeighbor(current.linkedNextId);
    prefetchNeighbor(current.linkedPrevId);
    for (final branch in _branches) {
      prefetchNeighbor(branch['to_photo_point_id'] as String?);
    }
  }

  Future<void> _reloadAndReturnTo(String photoPointId) async {
    final points = await _supabase.getPhotoPoints(widget.modelId);
    final idx = points.indexWhere((p) => p.id == photoPointId);
    _resetZoom();
    setState(() {
      _points = points;
      _currentIndex = idx == -1 ? 0 : idx;
      _direction = LookDirection.forward;
    });
    if (points.isNotEmpty) {
      _loadPinsForCurrent();
      _loadBranchesForCurrent();
      _prefetchCurrentAndNeighbors();
    }
  }

  void _moveForward() {
    if (_current.linkedNextId == null) return;
    final nextIdx = _points.indexWhere((p) => p.id == _current.linkedNextId);
    if (nextIdx == -1) return;
    _resetZoom();
    setState(() {
      _currentIndex = nextIdx;
      _direction = LookDirection.forward;
    });
    _loadPinsForCurrent();
    _loadBranchesForCurrent();
    _prefetchCurrentAndNeighbors();
  }

  void _moveBackward() {
    if (_current.linkedPrevId == null) return;
    final prevIdx = _points.indexWhere((p) => p.id == _current.linkedPrevId);
    if (prevIdx == -1) return;
    _resetZoom();
    setState(() {
      _currentIndex = prevIdx;
      _direction = LookDirection.forward;
    });
    _loadPinsForCurrent();
    _loadBranchesForCurrent();
    _prefetchCurrentAndNeighbors();
  }

  void _jumpToBranch(String toPhotoPointId) {
    final idx = _points.indexWhere((p) => p.id == toPhotoPointId);
    if (idx == -1) return;
    _resetZoom();
    setState(() {
      _currentIndex = idx;
      _direction = LookDirection.forward;
    });
    _loadPinsForCurrent();
    _loadBranchesForCurrent();
    _prefetchCurrentAndNeighbors();
  }

  /// Double-tap behavior:
  ///  - not zoomed: zoom in toward the tapped point and stay zoomed.
  ///  - already zoomed: advance to the next stop, or zoom back out if
  ///    this is the last stop.
  Future<void> _handleDoubleTap(Size photoSize) async {
    if (_zoomController.isAnimating) return;

    if (!_zoomedIn) {
      setState(() {
        _tapAlignment = Alignment(
          ((_doubleTapPosition.dx / photoSize.width) * 2 - 1).clamp(-1.0, 1.0),
          ((_doubleTapPosition.dy / photoSize.height) * 2 - 1).clamp(-1.0, 1.0),
        );
        _zoomedIn = true;
      });
      await _zoomController.forward();
      return;
    }

    if (_current.linkedNextId != null) {
      _moveForward(); // also resets the zoom
    } else {
      _zoomedIn = false;
      await _zoomController.reverse();
    }
  }

  void _lookLeft() {
    _resetZoom();
    setState(() => _direction = LookDirection.left);
  }

  void _lookRight() {
    _resetZoom();
    setState(() => _direction = LookDirection.right);
  }

  void _onPinTapped(SpatialPin pin) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PinHudPanel(pin: pin),
    ).then((_) => _loadPinsForCurrent());
  }

  Future<void> _onPhotoLongPress(Offset localPosition, Size photoSize) async {
    // Undo the zoom transform so the pin lands on the right spot of
    // the photo even when zoomed in.
    final scale = _zoomScale;
    final ax = (_tapAlignment.x + 1) / 2 * photoSize.width;
    final ay = (_tapAlignment.y + 1) / 2 * photoSize.height;
    final px = ax + (localPosition.dx - ax) / scale;
    final py = ay + (localPosition.dy - ay) / scale;
    final x = px / photoSize.width;
    final y = py / photoSize.height;
    try {
      final newPin = await _supabase.createPin(
        photoPointId: _current.id,
        x: x.clamp(0.0, 1.0),
        y: y.clamp(0.0, 1.0),
      );
      setState(() => _pins = [..._pins, newPin]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add pin: $e')),
        );
      }
    }
  }

  Future<void> _startBranchHere() async {
    final labelController = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a new branch'),
        content: TextField(
          controller: labelController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Left doorway'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(labelController.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    if (label == null || label.isEmpty || !mounted) return;

    final originalStopId = _current.id;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CaptureScreen(
          modelId: widget.modelId,
          branchFromPhotoPointId: originalStopId,
          branchLabel: label,
        ),
      ),
    );

    await _reloadAndReturnTo(originalStopId);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_points.isEmpty) {
      return const Scaffold(body: Center(child: Text('This walkthrough has no stops yet.')));
    }

    final cacheKey = _cacheKeyFor(_current, _direction);
    final resolvedFile = _resolvedFiles[cacheKey];
    if (resolvedFile == null) {
      // Not cached yet — kick off the fetch (idempotent) and show a
      // lightweight loading state in the meantime.
      _resolveAndCache(_current, _direction);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final photoSize = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (details) =>
                      _onPhotoLongPress(details.localPosition, photoSize),
                  onDoubleTapDown: (details) =>
                      _doubleTapPosition = details.localPosition,
                  onDoubleTap: () => _handleDoubleTap(photoSize),
                  child: AnimatedBuilder(
                    animation: _zoomController,
                    builder: (context, child) {
                      final scale = _zoomScale;
                      // Photo and pins zoom together so pins stay on
                      // the objects they mark; pins keep their size.
                      return Transform.scale(
                        scale: scale,
                        alignment: _tapAlignment,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            child!,
                            ..._pins.map((pin) => Positioned(
                                  left: pin.x * photoSize.width - 20,
                                  top: pin.y * photoSize.height - 20,
                                  child: Transform.scale(
                                    scale: 1 / scale,
                                    child: PinMarker(onTap: () => _onPinTapped(pin)),
                                  ),
                                )),
                          ],
                        ),
                      );
                    },
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutQuad,
                      switchOutCurve: Curves.easeInQuad,
                      transitionBuilder: (child, animation) {
                        final scaleAnimation = Tween(begin: 0.92, end: 1.0).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(scale: scaleAnimation, child: child),
                        );
                      },
                      child: resolvedFile != null
                          ? Image.file(
                              resolvedFile,
                              key: ValueKey(cacheKey),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                            )
                          : Container(
                              key: ValueKey('loading_$cacheKey'),
                              color: Colors.black,
                              width: double.infinity,
                              height: double.infinity,
                              child: const Center(
                                child: CircularProgressIndicator(color: Colors.white54),
                              ),
                            ),
                    ),
                  ),
                ),

                if (_branches.isNotEmpty)
                  Positioned(
                    bottom: 220,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Wrap(
                        spacing: 8,
                        children: _branches.map((b) {
                          return ActionChip(
                            backgroundColor: Colors.black54,
                            label: Text(b['label'] ?? 'Branch',
                                style: const TextStyle(color: Colors.cyanAccent)),
                            avatar: const Icon(Icons.call_split, color: Colors.cyanAccent, size: 16),
                            onPressed: () => _jumpToBranch(b['to_photo_point_id']),
                          );
                        }).toList(),
                      ),
                    ),
                  ),

                if (_pins.isEmpty)
                  Positioned(
                    bottom: 180,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'Double-tap to zoom · double-tap again for next stop · long-press to add a note',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ),
                  ),

                DirectionalNavArrows(
                  canMoveForward: _current.linkedNextId != null,
                  canMoveBackward: _current.linkedPrevId != null,
                  onForward: _moveForward,
                  onBackward: _moveBackward,
                  onLookLeft: _lookLeft,
                  onLookRight: _lookRight,
                ),

                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton(
                    icon: const Icon(Icons.call_split, color: Colors.white70),
                    tooltip: 'Start a branch from here',
                    onPressed: _startBranchHere,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}