import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import '../models/walkthrough_models.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../widgets/directional_nav_arrows.dart';
import '../widgets/pin_marker.dart';
import 'pin_hud_panel.dart';
import 'capture_screen.dart';

/// The core Matterport-style walkthrough screen: renders the current
/// photo_point's image for the active look direction, spatial pins
/// overlaid on it, directional nav arrows, and any labeled branches
/// leading off from this stop, plus a way for the owner to start a
/// brand-new branch from here.
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

  late final AnimationController _transitionController;
  static const _transitionDuration = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _transitionController = AnimationController(vsync: this, duration: _transitionDuration);
    _load();
  }

  @override
  void dispose() {
    _transitionController.dispose();
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
    }
  }

  /// Reloads the node list and returns to a SPECIFIC stop by its id —
  /// not by whatever numeric index it happened to be at before. The
  /// list gets rebuilt and reordered on reload (new branch stops get
  /// appended), so reusing the old index is fragile: it can silently
  /// land you on a completely different stop that happens to occupy
  /// the same position afterward. Matching by id is always correct
  /// regardless of how the list reorders.
  Future<void> _reloadAndReturnTo(String photoPointId) async {
    final points = await _supabase.getPhotoPoints(widget.modelId);
    final idx = points.indexWhere((p) => p.id == photoPointId);
    setState(() {
      _points = points;
      _currentIndex = idx == -1 ? 0 : idx;
      _direction = LookDirection.forward;
    });
    if (points.isNotEmpty) {
      _loadPinsForCurrent();
      _loadBranchesForCurrent();
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

  Future<void> _playTransitionThen(VoidCallback change) async {
    await _transitionController.forward(from: 0);
    setState(change);
    await _transitionController.reverse();
  }

  void _moveForward() {
    if (_current.linkedNextId == null) return;
    final nextIdx = _points.indexWhere((p) => p.id == _current.linkedNextId);
    if (nextIdx == -1) return;
    _playTransitionThen(() {
      _currentIndex = nextIdx;
      _direction = LookDirection.forward;
    }).then((_) {
      _loadPinsForCurrent();
      _loadBranchesForCurrent();
    });
  }

  void _moveBackward() {
    if (_current.linkedPrevId == null) return;
    final prevIdx = _points.indexWhere((p) => p.id == _current.linkedPrevId);
    if (prevIdx == -1) return;
    _playTransitionThen(() {
      _currentIndex = prevIdx;
      _direction = LookDirection.forward;
    }).then((_) {
      _loadPinsForCurrent();
      _loadBranchesForCurrent();
    });
  }

  void _jumpToBranch(String toPhotoPointId) {
    final idx = _points.indexWhere((p) => p.id == toPhotoPointId);
    if (idx == -1) return;
    _playTransitionThen(() {
      _currentIndex = idx;
      _direction = LookDirection.forward;
    }).then((_) {
      _loadPinsForCurrent();
      _loadBranchesForCurrent();
    });
  }

  void _lookLeft() {
    _playTransitionThen(() => _direction = LookDirection.left);
  }

  void _lookRight() {
    _playTransitionThen(() => _direction = LookDirection.right);
  }

  void _onPinTapped(SpatialPin pin) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PinHudPanel(pin: pin),
    );
  }

  Future<void> _onPhotoLongPress(Offset localPosition, Size photoSize) async {
    final x = localPosition.dx / photoSize.width;
    final y = localPosition.dy / photoSize.height;
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

    // Remember exactly which stop we're branching from, BY ID, so we
    // can return to that same physical spot afterward regardless of
    // how the reloaded list reorders itself.
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final photoSize = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                AnimatedBuilder(
                  animation: _transitionController,
                  builder: (context, child) {
                    final t = _transitionController.value;
                    return Opacity(
                      opacity: 1 - (t * 0.4),
                      child: Transform.scale(scale: 1 + (t * 0.06), child: child),
                    );
                  },
                  child: GestureDetector(
                    onLongPressStart: (details) =>
                        _onPhotoLongPress(details.localPosition, photoSize),
                    child: _WalkthroughPhoto(
                      modelId: widget.modelId,
                      photoPoint: _current,
                      direction: _direction,
                      cache: _cache,
                    ),
                  ),
                ),

                ..._pins.map((pin) => Positioned(
                      left: pin.x * photoSize.width - 20,
                      top: pin.y * photoSize.height - 20,
                      child: PinMarker(onTap: () => _onPinTapped(pin)),
                    )),

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

class _WalkthroughPhoto extends StatelessWidget {
  final String modelId;
  final PhotoPoint photoPoint;
  final LookDirection direction;
  final LocalCacheService cache;

  const _WalkthroughPhoto({
    required this.modelId,
    required this.photoPoint,
    required this.direction,
    required this.cache,
  });

  @override
  Widget build(BuildContext context) {
    final cacheKey = '${photoPoint.id}_${direction.name}';
    return FutureBuilder<File>(
      future: cache.getOrDownload(
        modelId: modelId,
        cacheKey: cacheKey,
        fetchSignedUrl: () async {
          final response = await Supabase.instance.client.functions.invoke(
            'r2-signed-url',
            body: {'object_key': photoPoint.urlFor(direction)},
          );
          final url = response.data?['url'] as String?;
          if (url == null) {
            throw Exception('r2-signed-url returned no url (status ${response.status})');
          }
          return url;
        },
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: Colors.white54));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Failed to load photo: ${snapshot.error}',
                style: const TextStyle(color: Colors.white70)),
          );
        }
        return Image.file(snapshot.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity);
      },
    );
  }
}