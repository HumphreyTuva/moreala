import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import '../models/walkthrough_models.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../widgets/directional_nav_arrows.dart';
import '../widgets/pin_marker.dart';
import 'pin_hud_panel.dart';

/// The core Matterport-style walkthrough screen: renders the current
/// photo_point's image for the active look direction, spatial pins
/// overlaid on it, and directional nav arrows. Tapping an arrow moves
/// to the next node (Forward) or changes look direction (Left/Right)
/// with a short pan/blur transition — never a hard cut, and never
/// auto-advancing (pacing is fully student-controlled per the spec).
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
  bool _loading = true;

  late final AnimationController _transitionController;
  static const _transitionDuration = Duration(milliseconds: 250); // 200-300ms per spec

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
    if (points.isNotEmpty) _loadPinsForCurrent();
  }

  Future<void> _loadPinsForCurrent() async {
    final pins = await _supabase.getPinsForPhotoPoint(_points[_currentIndex].id);
    if (mounted) setState(() => _pins = pins);
  }

  PhotoPoint get _current => _points[_currentIndex];

  Future<void> _playTransitionThen(VoidCallback change) async {
    // Lightweight pan/motion-blur scale transition. Kept as a simple
    // scale+fade rather than a real blur shader — blur shaders are
    // costly on low-end Android devices, which is the likely device
    // profile for this app given the pricing model.
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
    }).then((_) => _loadPinsForCurrent());
  }

  void _moveBackward() {
    if (_current.linkedPrevId == null) return;
    final prevIdx = _points.indexWhere((p) => p.id == _current.linkedPrevId);
    if (prevIdx == -1) return;
    _playTransitionThen(() {
      _currentIndex = prevIdx;
      _direction = LookDirection.forward;
    }).then((_) => _loadPinsForCurrent());
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
      // Stays open until the student closes it — no auto-dismiss timer,
      // per the "pacing is fully user-controlled" requirement.
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
                // Photo layer with fade/scale transition
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

                // Pin overlay
                ..._pins.map((pin) => Positioned(
                      left: pin.x * photoSize.width - 20,
                      top: pin.y * photoSize.height - 20,
                      child: PinMarker(onTap: () => _onPinTapped(pin)),
                    )),

                // Directional nav arrows
                DirectionalNavArrows(
                  canMoveForward: _current.linkedNextId != null,
                  canMoveBackward: _current.linkedPrevId != null,
                  onForward: _moveForward,
                  onBackward: _moveBackward,
                  onLookLeft: _lookLeft,
                  onLookRight: _lookRight,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Loads (from local cache first, falling back to a signed R2 URL) and
/// displays the photo for the current point + look direction.
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
