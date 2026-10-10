import '../../models/photo_entry.dart';

/// Exact time buckets: skips unrelated sessions without scanning the library.
/// Unknown timestamps remain eligible because absence is not negative evidence.
class TemporalCandidateIndex {
  TemporalCandidateIndex(this.items) {
    for (var i = 0; i < items.length; i++) {
      final time = items[i].capturedAt;
      if (time == null) {
        _untimed.add(i);
      } else {
        (_buckets[_bucket(time)] ??= []).add(i);
      }
    }
  }
  final List<PhotoEntry> items;
  final _buckets = <int, List<int>>{};
  final _untimed = <int>[];
  static const windowMilliseconds = 600000;
  int _bucket(DateTime time) =>
      time.millisecondsSinceEpoch ~/ windowMilliseconds;

  Iterable<int> candidates(int index, {required bool subjectMode}) sync* {
    final time = items[index].capturedAt;
    if (subjectMode || time == null) {
      for (var j = 0; j < items.length; j++) {
        if (j != index) yield j;
      }
      return;
    }
    yield* _untimed;
    final bucket = _bucket(time);
    for (var b = bucket - 1; b <= bucket + 1; b++) {
      for (final j in _buckets[b] ?? const <int>[]) {
        if (j != index &&
            time.difference(items[j].capturedAt!).inMilliseconds.abs() <=
                windowMilliseconds) {
          yield j;
        }
      }
    }
  }
}
