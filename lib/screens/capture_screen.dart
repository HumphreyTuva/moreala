import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../services/supabase_service.dart';

/// Stop-and-shoot walkthrough capture.
///
/// Flow per stop: Forward photo -> Left photo -> Right photo -> upload
/// all three -> link into the node graph -> repeat or finish.
enum _CaptureStage { forward, left, right, uploading }

class CaptureScreen extends StatefulWidget {
  final String modelId;
  const CaptureScreen({super.key, required this.modelId});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _supabase = SupabaseService();
  CameraController? _controller;
  _CaptureStage _stage = _CaptureStage.forward;
  int _stopCount = 0;
  String? _error;

  XFile? _forwardShot;
  XFile? _leftShot;
  XFile? _rightShot;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _syncStopCount();
  }

  /// Without this, reopening the capture screen (after backing out or
  /// an error) always restarted numbering stops from 0, silently
  /// overwriting earlier stops' photos in R2. This asks the database
  /// how many stops already exist and resumes from there.
  Future<void> _syncStopCount() async {
    final last = await _supabase.getLastPhotoPoint(widget.modelId);
    if (last != null && mounted) {
      setState(() => _stopCount = (last['order_index'] as int) + 1);
    }
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
      setState(() => _error = 'Camera init failed: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  String get _promptText {
    switch (_stage) {
      case _CaptureStage.forward:
        return 'Stop ${_stopCount + 1} — face forward, then tap capture';
      case _CaptureStage.left:
        return 'Now turn left, then tap capture';
      case _CaptureStage.right:
        return 'Now turn right, then tap capture';
      case _CaptureStage.uploading:
        return 'Saving this stop…';
    }
  }

  Future<void> _capture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final shot = await _controller!.takePicture();
      setState(() {
        switch (_stage) {
          case _CaptureStage.forward:
            _forwardShot = shot;
            _stage = _CaptureStage.left;
            break;
          case _CaptureStage.left:
            _leftShot = shot;
            _stage = _CaptureStage.right;
            break;
          case _CaptureStage.right:
            _rightShot = shot;
            _stage = _CaptureStage.uploading;
            break;
          case _CaptureStage.uploading:
            break;
        }
      });
      if (_stage == _CaptureStage.uploading) {
        await _uploadStopAndAdvance();
      }
    } catch (e) {
      setState(() => _error = 'Capture failed: $e');
    }
  }

  /// Lets the student redo whichever shot they're currently reviewing,
  /// without losing earlier shots in this same stop. Only shown after
  /// at least one shot has been taken (there's nothing to retake before
  /// the Forward photo exists).
  void _retake(_CaptureStage stageToRetake) {
    setState(() {
      switch (stageToRetake) {
        case _CaptureStage.forward:
          _forwardShot = null;
          _stage = _CaptureStage.forward;
          break;
        case _CaptureStage.left:
          _leftShot = null;
          _stage = _CaptureStage.left;
          break;
        case _CaptureStage.right:
          _rightShot = null;
          _stage = _CaptureStage.right;
          break;
        case _CaptureStage.uploading:
          break;
      }
    });
  }

  Future<void> _uploadStopAndAdvance() async {
    try {
      final forwardKey = 'models/${widget.modelId}/${_stopCount}_forward.jpg';
      final leftKey = 'models/${widget.modelId}/${_stopCount}_left.jpg';
      final rightKey = 'models/${widget.modelId}/${_stopCount}_right.jpg';

      await _uploadOne(_forwardShot!, forwardKey);
      await _uploadOne(_leftShot!, leftKey);
      await _uploadOne(_rightShot!, rightKey);

      await _supabase.createPhotoPointStop(
        modelId: widget.modelId,
        forwardKey: forwardKey,
        leftKey: leftKey,
        rightKey: rightKey,
      );

      setState(() {
        _stopCount += 1;
        _forwardShot = null;
        _leftShot = null;
        _rightShot = null;
        _stage = _CaptureStage.forward;
      });
    } catch (e) {
      // On failure, drop back to the Forward stage for THIS stop
      // rather than leaving the UI stuck on "uploading" — the student
      // can just redo all three shots for this stop and try again.
      setState(() {
        _error = 'Upload failed: $e';
        _stage = _CaptureStage.forward;
        _forwardShot = null;
        _leftShot = null;
        _rightShot = null;
      });
    }
  }

  /// Compresses/resizes before upload — brings file size down toward
  /// the spec's ~150-300KB target (still JPEG, not WebP; Dart's `image`
  /// package doesn't encode WebP, only decode it — true WebP output
  /// would need a platform channel or server-side conversion, flagged
  /// here rather than silently left out).
  Future<Uint8List> _compress(XFile file) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes; // fall back to original if decode fails

    final resized = decoded.width > 1280
        ? img.copyResize(decoded, width: 1280)
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 75));
  }

  Future<void> _uploadOne(XFile file, String objectKey) async {
    final uploadUrl = await _supabase.getUploadUrl(objectKey);
    final bytes = await _compress(file);
    final res = await http.put(
      Uri.parse(uploadUrl),
      body: bytes,
      headers: {'Content-Type': 'image/jpeg'},
    );
    if (res.statusCode >= 300) {
      throw Exception('R2 upload of $objectKey failed: HTTP ${res.statusCode}');
    }
  }

  Future<void> _finishWalkthrough() async {
    if (_stopCount == 0) {
      setState(() => _error = 'Capture at least one stop before finishing.');
      return;
    }
    await _supabase.markModelReady(widget.modelId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isUploading = _stage == _CaptureStage.uploading;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: CameraPreview(_controller!)),

          // Thumbnails of shots taken so far this stop — tap one to retake it
          Positioned(
            top: 48,
            right: 16,
            child: Row(
              children: [
                if (_forwardShot != null)
                  _thumb(_forwardShot!, 'F', onTap: () => _retake(_CaptureStage.forward)),
                if (_leftShot != null)
                  _thumb(_leftShot!, 'L', onTap: () => _retake(_CaptureStage.left)),
                if (_rightShot != null)
                  _thumb(_rightShot!, 'R', onTap: () => _retake(_CaptureStage.right)),
              ],
            ),
          ),

          Positioned(
            top: 48,
            left: 16,
            right: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _promptText,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                if (!isUploading &&
                    (_forwardShot != null || _leftShot != null || _rightShot != null))
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('Tap a thumbnail to retake it',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
              ],
            ),
          ),

          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Center(
                  child: isUploading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : GestureDetector(
                          onTap: _capture,
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 20),
                if (!isUploading && _stage == _CaptureStage.forward && _stopCount > 0)
                  TextButton(
                    onPressed: _finishWalkthrough,
                    child: Text('Finish walkthrough ($_stopCount stops captured)',
                        style: const TextStyle(color: Colors.cyanAccent)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(XFile file, String label, {required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(File(file.path), width: 44, height: 44, fit: BoxFit.cover),
            ),
            Container(
              width: 44,
              color: Colors.black54,
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }
}
