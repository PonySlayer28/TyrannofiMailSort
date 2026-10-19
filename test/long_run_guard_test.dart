import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/services/long_run_guard.dart';

/// The guard decides whether a running sort survives the user switching apps.
/// Its timing and its counting are the whole mechanism, so both are pinned
/// down here — including the case where the operation throws, which is exactly
/// when a stranded "still working" notification would be most misleading.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tyrannofi/longrun');
  late List<String> calls;

  setUp(() {
    calls = [];
    LongRunGuard.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    LongRunGuard.resetForTest();
  });

  test('short work never raises a service', () {
    fakeAsync((async) {
      LongRunGuard.begin();
      async.elapse(const Duration(seconds: 5));
      LongRunGuard.end();
      async.elapse(const Duration(minutes: 1));
    });
    expect(calls, isEmpty,
        reason: 'A seconds-long action must not flash a notification — '
            'otherwise users mute it.');
  });

  test('work outliving the threshold is protected', () {
    fakeAsync((async) {
      LongRunGuard.begin();
      async.elapse(LongRunGuard.threshold + const Duration(seconds: 1));
      expect(calls, contains('start'));
      expect(LongRunGuard.isActive, isTrue);
      LongRunGuard.end();
      async.elapse(const Duration(seconds: 1));
    });
    expect(calls, containsAllInOrder(['start', 'stop']));
    expect(LongRunGuard.isActive, isFalse);
  });

  test('nested operations do not end the service early', () {
    fakeAsync((async) {
      LongRunGuard.begin(); // outer batch run
      async.elapse(LongRunGuard.threshold + const Duration(seconds: 1));
      expect(calls, contains('start'));

      LongRunGuard.begin(); // inner single step
      LongRunGuard.end(); // its end must not take the service down
      async.elapse(const Duration(seconds: 1));
      expect(LongRunGuard.isActive, isTrue,
          reason: 'The inner call did not start the service and must not '
              'pull it out from under the outer one.');
      expect(calls.where((c) => c == 'stop'), isEmpty);

      LongRunGuard.end(); // only now
      async.elapse(const Duration(seconds: 1));
    });
    expect(LongRunGuard.isActive, isFalse);
    expect(calls.last, 'stop');
  });

  test('a thrown operation still releases the service', () async {
    await expectLater(
      LongRunGuard.run('Test', () async => throw StateError('broken')),
      throwsA(isA<StateError>()),
    );
    expect(LongRunGuard.depth, 0,
        reason: 'A crashed run must not leave a notification claiming '
            'work is still going on.');
    expect(LongRunGuard.isActive, isFalse);
  });

  test('an unpaired end cannot push the counter below zero', () {
    LongRunGuard.end();
    LongRunGuard.end();
    expect(LongRunGuard.depth, 0);
    LongRunGuard.begin();
    expect(LongRunGuard.depth, 1,
        reason: 'Otherwise the next real run would never get above zero '
            'and would stay unprotected.');
  });

  test('progress is only sent while the service runs, and not repeated', () {
    fakeAsync((async) {
      LongRunGuard.begin();
      LongRunGuard.progress('1 of 10'); // no service yet
      expect(calls, isEmpty);

      async.elapse(LongRunGuard.threshold + const Duration(seconds: 1));
      calls.clear();

      LongRunGuard.progress('2 of 10');
      LongRunGuard.progress('2 of 10'); // unchanged
      expect(calls.where((c) => c == 'update').length, 1,
          reason: 'Progress fires per mail batch; resending unchanged text '
              'would mean thousands of channel calls.');
      LongRunGuard.end();
      async.elapse(const Duration(seconds: 1));
    });
  });
}
