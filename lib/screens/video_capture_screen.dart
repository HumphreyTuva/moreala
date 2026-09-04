import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import 'package:video_player/video_player.dart';
import '../services/supabase_service.dart';
import 'walkthrough_screen.dart';

/// Video-based capture, done ENTIRELY on-device — no server, no
/// cloud worker, no hosting bill. Records one continuous walkthrough
/// video, then extracts frames locally at fixed intervals using the
/// phone's own hardware video decoder (via video_thumbnail), uploads
/// each as a stop, and links them into the node graph automatically.
///
/// Deliberate simplification vs. the stop-and-shoot mode: since this
/// is one continuous forward-facing video, only a Forward image is
/// captured per stop — there's no separate Left/Right angle the way
/// stop-and-shoot gets by having the student physically turn at each
/// spot. WalkthroughScreen already falls back to the Forward image
/// when Left/Right aren't set, so navigation still works, just
/// without the side-look photos at each video-mode stop.
///
/// HONEST NOTE ON SPEED: extraction happens on the student's own
/// phone before upload even starts. On a low-end Android device, a
/// longer video could take real time (well over a minute) and some
/// battery to process. If this turns out too slow in practice, the
/// fix is a paid cloud worker doing the same job server-side instead
/// — that's a genuine tradeoff to make with real usage data, not
/// something to guess at now.
class VideoCaptureScreen extends StatefulWidget {
  final String modelId;
  const VideoCaptureScreen({super.key, required this.modelId});

  @override
  State<VideoCaptureScreen> createState() => _VideoCaptureScreenState();
}

enum _Stage { recording, extracting, uploading, done, failed }

// Cap how many stops one video can generate — a very long recording
// shouldn't turn into an unbounded processing/upload job on someone's
// phone. If the video is longer than this would allow at 2s spacing,
// the interval widens instead of the frame count exploding.
const int _maxStops = 60;
const int _targetIntervalMs = 2000;

class _VideoCaptureScreenState extends State<VideoCaptureScreen> {
  final _supabase = SupabaseService();
  CameraController? _controller;
  bool _isRecording = false;
  _Stage _stage = _Stage.recording;
  String? _error;
  int _extractedCount = 0;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(backCamera, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      if (mounted) setState(() => _controller = controller);
    } catch (e) {
      setState(() {
        _stage = _Stage.failed;
        _error = 'Camera init failed: $e';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    await _controller!.startVideoRecording();
    setState(() => _isRecording = true);
  }

  Future<void> _stopAndProcess() async {
    if (_controller == null || !_isRecording) return;
    final file = await _controller!.stopVideoRecording();
    setState(() {
      _isRecording = false;
      _stage = _Stage.extracting;
    });

    try {
      await _extractAndUploadFrames(file.path);
      await _supabase.markModelReady(widget.modelId);
      if (mounted) setState(() => _stage = _Stage.done);
    } catch (e) {
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
    }
  }

  Future<void> _extractAndUploadFrames(String videoPath) async {
    // Read the recorded video's duration — briefly initialize a
    // player just for this, no actual playback happens.
    final playerController = VideoPlayerController.file(File(videoPath));
    await playerController.initialize();
    final durationMs = playerController.value.duration.inMilliseconds;
    await playerController.dispose();

    if (durationMs <= 0) {
      throw Exception('Could not read video duration — the recording may be corrupt.');
    }

    // Space frames evenly; widen the interval rather than exceeding
    // _maxStops for a long recording.
    final naturalCount = (durationMs / _targetIntervalMs).ceil().clamp(1, 999999);
    final stopCount = naturalCount > _maxStops ? _maxStops : naturalCount;
    final actualIntervalMs = durationMs / stopCount;

    setState(() => _totalCount = stopCount);

    String? lastPhotoPointId;

    for (var i = 0; i < stopCount; i++) {
      final timestampMs = (i * actualIntervalMs).round().clamp(0, durationMs - 1);

      final Uint8List? frameBytes = await vt.VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: vt.ImageFormat.JPEG,
        timeMs: timestampMs,
        quality: 70,
        maxWidth: 1280,
      );

      if (frameBytes == null) {
        // Skip a frame the decoder couldn't produce (can happen right
        // at the very start/end of a clip) rather than failing the
        // whole walkthrough over one bad frame.
        continue;
      }

      final objectKey = 'models/${widget.modelId}/${i}_forward.jpg';
      final uploadUrl = await _supabase.getUploadUrl(objectKey);
      final res = await http.put(
        Uri.parse(uploadUrl),
        body: frameBytes,
        headers: {'Content-Type': 'image/jpeg'},
      );
      if (res.statusCode >= 300) {
        throw Exception('Upload of frame $i failed: HTTP ${res.statusCode}');
      }

      final newStop = await _supabase.createPhotoPointStop(
        modelId: widget.modelId,
        forwardKey: objectKey,
        // No distinct Left/Right in video mode — see class doc
        // comment. WalkthroughScreen falls back to Forward for these.
        leftKey: objectKey,
        rightKey: objectKey,
        previousPhotoPointId: lastPhotoPointId,
      );
      lastPhotoPointId = newStop.id;

      if (mounted) setState(() => _extractedCount = i + 1);
    }

    if (lastPhotoPointId == null) {
      throw Exception('No frames could be extracted from this video — try recording again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.extracting:
      case _Stage.uploading:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    value: _totalCount > 0 ? _extractedCount / _totalCount : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _totalCount > 0
                        ? 'Processing stop $_extractedCount of $_totalCount…'
                        : 'Reading video…',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This happens on your phone — a longer video may take a little while.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        );
      case _Stage.done:
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Colors.cyanAccent, size: 64),
                const SizedBox(height: 16),
                Text('Your walkthrough is ready! ($_totalCount stops)'),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => WalkthroughScreen(modelId: widget.modelId),
                    ),
                  ),
                  child: const Text('View walkthrough'),
                ),
              ],
            ),
          ),
        );
      case _Stage.failed:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
                  const SizedBox(height: 16),
                  Text(_error ?? 'Something went wrong.', textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          ),
        );
      case _Stage.recording:
        if (_controller == null || !_controller!.value.isInitialized) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(child: CameraPreview(_controller!)),
              Positioned(
                top: 48,
                left: 16,
                right: 16,
                child: Text(
                  _isRecording
                      ? 'Recording — walk steadily through the space'
                      : 'Tap to start recording your walkthrough',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _isRecording ? _stopAndProcess : _startRecording,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                        color: _isRecording ? Colors.red : Colors.transparent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}