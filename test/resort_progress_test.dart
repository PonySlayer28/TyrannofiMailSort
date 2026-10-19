import 'package:flutter_test/flutter_test.dart';

/// What a resumable folder run has to get right, as plain set arithmetic.
///
/// The run itself needs a live IMAP connection and cannot be exercised here.
/// What can be pinned down is the rule it follows, and that rule is where the
/// danger sits: record a folder too early and its remaining mail is never
/// looked at again.
List<String> pending(List<String> all, Set<String> finished) =>
    all.where((f) => !finished.contains(f)).toList();

void main() {
  const all = ['Shopping/Amazon', 'Amazon', 'Paypal', 'Entwürfe'];

  group('what a resumed run still has to do', () {
    test('nothing recorded yet means everything is pending', () {
      expect(pending(all, {}), all);
    });

    test('a recorded folder is not offered again', () {
      expect(pending(all, {'Amazon'}),
          ['Shopping/Amazon', 'Paypal', 'Entwürfe']);
    });

    test('a folder that failed stays pending, so the retry happens', () {
      // Only clean folders are recorded. Of the 13 that hiccuped in the first
      // bulk run, 12 went through on the second attempt — that only works if a
      // failure leaves the folder in the list.
      final finished = <String>{'Shopping/Amazon', 'Amazon'};
      expect(pending(all, finished), ['Paypal', 'Entwürfe']);
    });

    test('order survives, which is what keeps the tree from collapsing', () {
      // Deepest first, and `Shopping/Amazon` before `Amazon`: skipping the
      // done ones must not reshuffle what is left, or `Amazon` gets deleted as
      // empty a moment before its mail arrives.
      expect(pending(all, {'Paypal'}),
          ['Shopping/Amazon', 'Amazon', 'Entwürfe']);
    });

    test('a finished run leaves nothing pending', () {
      expect(pending(all, all.toSet()), isEmpty);
    });

    test('a record naming a folder that no longer exists is harmless', () {
      // A resort deletes emptied folders, so the next LIST is shorter than the
      // record. Nothing looks the record up by folder; it is only ever asked
      // whether a folder it holds is in it.
      expect(pending(all, {'Gaming/PlayAsia', 'Amazon'}),
          ['Shopping/Amazon', 'Paypal', 'Entwürfe']);
    });
  });
}
