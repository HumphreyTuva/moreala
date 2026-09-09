import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../services/supabase_service.dart';
import '../widgets/error_banner.dart';
import '../utils/image_utils.dart';

/// Future<Uint8List>
///
/// Flow per stop: Forward photo -> Left photo -> Right photo -> upload
/// all three -> link into the node graph -> repeat or finish.
enum _CaptureStage { forward, left, right, uploading }

class CaptureScreen extends StatefulWidget {
  final String modelId;
  // When set, this capture session starts a brand-new branch off an
  // existing stop rather than continuing the main line. The new
  // stop's connection to the graph is recorded via a labeled
  // photo_point_links row (branchLabel), not the normal
  // linked_prev_id/linked_next_id chain.
  final String? branchFromPhotoPointId;
  final String? branchLabel;

  const CaptureScreen({
    super.key,
    required this.modelId,
    this.branchFromPhotoPointId,
    this.branchLabel,
  });

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _supabase = SupabaseService();
  CameraController? _controller;
  _CaptureStage _stage = _CaptureStage.forward;
  int _stopCount = 0;
  String? _error;

  bool _uploadFailed = false;

  String? _lastPhotoPointId;
  bool _isFirstStopOfBranch = false;

  XFile? _forwardShot;
  XFile? _leftShot;
  XFile? _rightShot;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _isFirstStopOfBranch = widget.branchFromPhotoPointId != null;
    _syncStopCount();
  }

  Future<void> _syncStopCount() async {
    final last = await _supabase.getLastPhotoPoint(widget.modelId);
    if (last != null && mounted) {
      setState(() {
        _stopCount = (last['order_index'] as int) + 1;
        if (widget.branchFromPhotoPointId == null) {
          _lastPhotoPointId = last['id'] as String;
        }
      });
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
    if (_uploadFailed) return 'Upload failed — check your connection and retry';
    final branchPrefix = widget.branchFromPhotoPointId != null
        ? '[${widget.branchLabel ?? "Branch"}] '
        : '';
    switch (_stage) {
      case _CaptureStage.forward:
        return '$branchPrefix''Stop ${_stopCount + 1} — face forward, then tap capture';
      case _CaptureStage.left:
        return '$branchPrefix''Now turn left, then tap capture';
      case _CaptureStage.right:
        return '$branchPrefix''Now turn right, then tap capture';
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
    setState(() => _uploadFailed = false);
    try {
      final forwardKey = 'models/${widget.modelId}/${_stopCount}_forward.jpg';
      final leftKey = 'models/${widget.modelId}/${_stopCount}_left.jpg';
      final rightKey = 'models/${widget.modelId}/${_stopCount}_right.jpg';

      await _uploadOneWithRetry(_forwardShot!, forwardKey);
      await _uploadOneWithRetry(_leftShot!, leftKey);
      await _uploadOneWithRetry(_rightShot!, rightKey);

      final newStop = await _supabase.createPhotoPointStop(
        modelId: widget.modelId,
        forwardKey: forwardKey,
        leftKey: leftKey,
        rightKey: rightKey,
        previousPhotoPointId: _lastPhotoPointId,
      );

      if (_isFirstStopOfBranch && widget.branchFromPhotoPointId != null) {
        await _supabase.createBranchLink(
          fromPhotoPointId: widget.branchFromPhotoPointId!,
          toPhotoPointId: newStop.id,
          label: widget.branchLabel ?? 'Branch',
        );
        _isFirstStopOfBranch = false;
      }

      _lastPhotoPointId = newStop.id;

      setState(() {
        _stopCount += 1;
        _forwardShot = null;
        _leftShot = null;
        _rightShot = null;
        _stage = _CaptureStage.forward;
      });
    } catch (e) {
      setState(() {
        _uploadFailed = true;
        _error = 'Upload failed after retries: $e';
      });
    }
  }

  Future<void> _uploadOneWithRetry(XFile file, String objectKey) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _uploadOne(file, objectKey);
        return;
      } catch (e) {
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  Future<Uint8List> _compress(XFile file) async {
    final bytes = await file.readAsBytes();
    return normalizeAndCompress(bytes, maxWidth: 1280, quality: 75);
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
    if (_error != null && !_uploadFailed) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
             
              children: [
                ErrorBanner(message: _error!),
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

    final isUploading = _stage == _CaptureStage.uploading && !_uploadFailed;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: CameraPreview(_controller!)),

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
                  style: TextStyle(
                    color: _uploadFailed ? Colors.orangeAccent : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!isUploading &&
                    !_uploadFailed &&
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
                if (_uploadFailed)
                  ElevatedButton.icon(
                    onPressed: _uploadStopAndAdvance,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry upload'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
                  )
                else
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
                if (!isUploading &&
                    !_uploadFailed &&
                    _stage == _CaptureStage.forward &&
                    _stopCount > 0)
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