/// SM-2 Spaced Repetition Algorithm.
///
/// Standard implementation (Piotr Wozniak's SuperMemo-2). Call
/// [Sm2Service.review] with the student's self-rated recall quality
/// (0-5, we expose it to the UI as 1-5 per the spec, mapped down by 1)
/// and the previous review state, and it returns the next state.
library;

class Sm2Result {
  final double easeFactor;
  final int interval; // days until next review
  final int repetitions;
  final DateTime nextReviewDate;

  const Sm2Result({
    required this.easeFactor,
    required this.interval,
    required this.repetitions,
    required this.nextReviewDate,
  });
}

class Sm2Service {
  /// [quality] is 0-5:
  ///   0-2 = failed recall (student didn't know it)
  ///   3-5 = successful recall, with 5 being "trivially easy"
  ///
  /// The UI's 1-5 difficulty rating should map: UI 1 -> quality 0,
  /// UI 2 -> quality 2, UI 3 -> quality 3, UI 4 -> quality 4, UI 5 -> quality 5.
  /// (i.e. UI "1 - Again" is treated as a fail, not a low pass.)
  static Sm2Result review({
    required int quality,
    required double previousEaseFactor,
    required int previousInterval,
    required int previousRepetitions,
    DateTime? now,
  }) {
    assert(quality >= 0 && quality <= 5);
    now ??= DateTime.now();

    double ef = previousEaseFactor;
    int repetitions = previousRepetitions;
    int interval;

    if (quality < 3) {
      // Failed recall: reset repetition count, review again tomorrow.
      repetitions = 0;
      interval = 1;
    } else {
      repetitions += 1;
      if (repetitions == 1) {
        interval = 1;
      } else if (repetitions == 2) {
        interval = 6;
      } else {
        interval = (previousInterval * ef).round();
      }
    }

    // Ease factor update (applies regardless of pass/fail, per SM-2 spec).
    ef = ef + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
    if (ef < 1.3) ef = 1.3; // floor, per original algorithm

    final nextDate = DateTime(now.year, now.month, now.day).add(Duration(days: interval));

    return Sm2Result(
      easeFactor: double.parse(ef.toStringAsFixed(2)),
      interval: interval,
      repetitions: repetitions,
      nextReviewDate: nextDate,
    );
  }
}
