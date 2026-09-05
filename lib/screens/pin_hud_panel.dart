import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../models/walkthrough_models.dart';
import '../services/supabase_service.dart';
import '../services/sm2_service.dart';

/// Frosted glass modal for a tapped pin. States:
///   1. No note yet -> form to create one (text / flashcard / audio).
///   2. Text note -> displayed, with delete.
///   3. Flashcard -> question -> Show Answer -> rate 1-5 -> SM-2, with delete.
///   4. Audio note -> play button, with delete.
/// Stays open until the student dismisses it (no auto-close timer).
class PinHudPanel extends StatefulWidget {
  final SpatialPin pin;
  const PinHudPanel({super.key, required this.pin});

  @override
  State<PinHudPanel> createState() => _PinHudPanelState();
}

class _PinHudPanelState extends State<PinHudPanel> {
  final _supabase = SupabaseService();
  StudyNote? _note;
  bool _loading = true;
  bool _answerShown = false;

  NoteType _newNoteType = NoteType.text;
  final _bodyController = TextEditingController();
  final _questionController = TextEditingController();
  final _answerController = TextEditingController();
  bool _saving = false;

  final _recorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordedFilePath;

  final _player = AudioPlayer();
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _load();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _bodyController.dispose();
    _questionController.dispose();
    _answerController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.pin.noteId != null) {
      final note = await _supabase.getNoteById(widget.pin.noteId!);
      if (mounted) setState(() {
        _note = note;
        _loading = false;
      });
    } else {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startRecording() async {
    if (await _recorder.hasPermission()) {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(), path: path);
      setState(() => _isRecording = true);
    }
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    setState(() {
      _isRecording = false;
      _recordedFilePath = path;
    });
  }

  Future<void> _saveNewNote() async {
    setState(() => _saving = true);
    try {
      Map<String, dynamic> content = {};
      String? mediaUrl;

      if (_newNoteType == NoteType.flashcard) {
        content = {
          'question': _questionController.text.trim(),
          'answer': _answerController.text.trim(),
        };
      } else if (_newNoteType == NoteType.text) {
        content = {'body': _bodyController.text.trim()};
      } else if (_newNoteType == NoteType.audio) {
        if (_recordedFilePath == null) {
          setState(() => _saving = false);
          return;
        }
        final bytes = await File(_recordedFilePath!).readAsBytes();
        mediaUrl = await _supabase.uploadVoiceNote(bytes);
      }

      final note = await _supabase.createNote(
        pinId: widget.pin.id,
        type: _newNoteType,
        content: content,
        mediaUrl: mediaUrl,
      );
      if (mounted) setState(() => _note = note);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rateDifficulty(int uiRating) async {
    if (_note == null) return;
    final qualityMap = {1: 0, 2: 2, 3: 3, 4: 4, 5: 5};
    final quality = qualityMap[uiRating]!;

    final previous = await _supabase.getReviewState(_note!.id);
    final result = Sm2Service.review(
      quality: quality,
      previousEaseFactor: (previous?['ease_factor'] as num?)?.toDouble() ?? 2.5,
      previousInterval: previous?['interval'] as int? ?? 1,
      previousRepetitions: previous?['repetitions'] as int? ?? 0,
    );

    await _supabase.submitReview(
      noteId: _note!.id,
      easeFactor: result.easeFactor,
      interval: result.interval,
      repetitions: result.repetitions,
      nextReviewDate: result.nextReviewDate,
    );

    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }
    final signedUrl = await _supabase.getVoiceNoteSignedUrl(_note!.mediaUrl!);
    await _player.play(UrlSource(signedUrl));
  }

  Future<void> _confirmDeletePin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this pin?'),
        content: const Text('This removes the pin and its note permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _supabase.deletePin(widget.pin.id, noteId: widget.pin.noteId);
      if (mounted) Navigator.of(context).pop();
    }
  }

  IconData get _typeIcon {
    switch (_note?.type) {
      case NoteType.flashcard:
        return Icons.style;
      case NoteType.audio:
        return Icons.mic;
      default:
        return Icons.sticky_note_2;
    }
  }

  String get _typeLabel {
    switch (_note?.type) {
      case NoteType.flashcard:
        return 'Flashcard';
      case NoteType.audio:
        return 'Voice note';
      default:
        return 'Note';
    }
  }

    @override
  Widget build(BuildContext context) {
    // Shrinks the space available to the sheet by the keyboard's
    // height BEFORE DraggableScrollableSheet computes its fractional
    // sizes — that's what actually makes the sheet move up and fit
    // above the keyboard, rather than just padding content inside a
    // box that stayed the same size (which is what happened before:
    // the sheet's height never changed, so the keyboard just covered
    // most of it regardless).
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.4), width: 1),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.all(24),
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                    : _note == null
                        ? _buildCreateForm(scrollController)
                        : _buildNoteContent(scrollController),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCreateForm(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add a note to this spot',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          SegmentedButton<NoteType>(
            segments: const [
              ButtonSegment(value: NoteType.text, label: Text('Note')),
              ButtonSegment(value: NoteType.flashcard, label: Text('Flashcard')),
              ButtonSegment(value: NoteType.audio, label: Text('Voice')),
            ],
            selected: {_newNoteType},
            onSelectionChanged: (s) => setState(() => _newNoteType = s.first),
          ),
          const SizedBox(height: 16),
          if (_newNoteType == NoteType.text)
            TextField(
              controller: _bodyController,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'What do you want to remember here?',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
              ),
            )
          else if (_newNoteType == NoteType.flashcard) ...[
            TextField(
              controller: _questionController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Question',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _answerController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Answer',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.cyanAccent)),
              ),
            ),
          ] else
            _buildRecordingUi(),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _saving ? null : _saveNewNote,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent.shade700),
            child: _saving
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingUi() {
    if (_recordedFilePath != null) {
      return Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.cyanAccent, size: 20),
          const SizedBox(width: 8),
          const Text('Recording ready', style: TextStyle(color: Colors.white70)),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _recordedFilePath = null),
            child: const Text('Redo'),
          ),
        ],
      );
    }
    return Center(
      child: GestureDetector(
        onTap: _isRecording ? _stopRecording : _startRecording,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isRecording ? Colors.redAccent : Colors.white10,
            border: Border.all(color: Colors.cyanAccent),
          ),
          child: Icon(_isRecording ? Icons.stop : Icons.mic, color: Colors.white),
        ),
      ),
    );
  }

  /// Shared header for every existing-note view: an icon + label
  /// showing what kind of note this is, with the delete action
  /// aligned on the same row — not floating separately above the
  /// content the way it did before.
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(_typeIcon, color: Colors.cyanAccent, size: 20),
            const SizedBox(width: 8),
            Text(_typeLabel,
                style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          tooltip: 'Delete this pin',
          onPressed: _confirmDeletePin,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildNoteContent(ScrollController scrollController) {
    if (_note!.type == NoteType.text) {
      return SingleChildScrollView(
        controller: scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            Text(
              _note!.content['body'] ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (_note!.type == NoteType.audio) {
      return Column(
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          Center(
            child: GestureDetector(
              onTap: _togglePlayback,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.cyanAccent.withOpacity(0.15),
                  border: Border.all(color: Colors.cyanAccent),
                ),
                child: Icon(
                  _isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.cyanAccent,
                  size: 36,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Flashcard
    return SingleChildScrollView(
      controller: scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          Text(
            _note!.content['question'] ?? '',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          if (!_answerShown)
            ElevatedButton(
              onPressed: () => setState(() => _answerShown = true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent.shade700),
              child: const Text('Show Answer'),
            )
          else ...[
            Text(_note!.content['answer'] ?? '',
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 24),
            const Text('How hard was that to recall?',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(5, (i) => _difficultyButton(i + 1)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _difficultyButton(int rating) {
    return GestureDetector(
      onTap: () => _rateDifficulty(rating),
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.08),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
        ),
        child: Text('$rating', style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}