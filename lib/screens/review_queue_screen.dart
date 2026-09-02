import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../services/sm2_service.dart';

/// "What's due today" — pulls every flashcard across all the
/// student's walkthroughs whose next_review_date has arrived, and
/// lets them work through the pile right here, without needing to
/// hunt down each pin individually inside its walkthrough.
class ReviewQueueScreen extends StatefulWidget {
  const ReviewQueueScreen({super.key});

  @override
  State<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends State<ReviewQueueScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>> _queue = [];
  int _index = 0;
  bool _loading = true;
  bool _answerShown = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final due = await _supabase.getDueReviewsWithContext();
      // Only flashcards make sense in an active-recall review queue —
      // text notes don't have a question/answer/difficulty cycle.
      final flashcardsOnly = due.where((r) {
        final note = r['notes'];
        return note != null && note['type'] == 'flashcard';
      }).toList();

      if (mounted) {
        setState(() {
          _queue = flashcardsOnly;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Failed to load: $e';
        });
      }
    }
  }

  Map<String, dynamic>? get _current => _index < _queue.length ? _queue[_index] : null;

  Future<void> _rate(int uiRating) async {
    final review = _current;
    if (review == null) return;
    final note = review['notes'];

    final qualityMap = {1: 0, 2: 2, 3: 3, 4: 4, 5: 5};
    final result = Sm2Service.review(
      quality: qualityMap[uiRating]!,
      previousEaseFactor: (review['ease_factor'] as num?)?.toDouble() ?? 2.5,
      previousInterval: review['interval'] as int? ?? 1,
      previousRepetitions: review['repetitions'] as int? ?? 0,
    );

    await _supabase.submitReview(
      noteId: note['id'],
      easeFactor: result.easeFactor,
      interval: result.interval,
      repetitions: result.repetitions,
      nextReviewDate: result.nextReviewDate,
    );

    setState(() {
      _index++;
      _answerShown = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Due Today')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                )
              : _queue.isEmpty
                  ? const Center(
                      child: Text('Nothing due right now — check back later.',
                          style: TextStyle(color: Colors.white54)),
                    )
                  : _current == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.check_circle, color: Colors.cyanAccent, size: 64),
                              const SizedBox(height: 16),
                              Text('All ${_queue.length} caught up for now.',
                                  style: const TextStyle(fontSize: 16)),
                            ],
                          ),
                        )
                      : _buildCard(_current!),
    );
  }

  Widget _buildCard(Map<String, dynamic> review) {
    final note = review['notes'];

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_index + 1} of ${_queue.length}',
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(height: 24),
          Text(
            note?['content']?['question'] ?? '',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 32),
          if (!_answerShown)
            ElevatedButton(
              onPressed: () => setState(() => _answerShown = true),
              child: const Text('Show Answer'),
            )
          else ...[
            Text(
              note?['content']?['answer'] ?? '',
              style: const TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const SizedBox(height: 32),
            const Text('How hard was that to recall?',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 12),
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
      onTap: () => _rate(rating),
      child: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.08),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
        ),
        child: Text('$rating'),
      ),
    );
  }
}