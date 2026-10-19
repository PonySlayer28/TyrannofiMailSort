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
        reason: 'Eine Sekundenaktion darf keine Benachrichtigung aufblitzen '
            'lassen — sonst wird sie stummgeschaltet.');
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
      LongRunGuard.begin(); // äußerer Stapellauf
      async.elapse(LongRunGuard.threshold + const Duration(seconds: 1));
      expect(calls, contains('start'));

      LongRunGuard.begin(); // innerer Einzelschritt
      LongRunGuard.end(); // dessen Ende darf den Dienst nicht mitnehmen
      async.elapse(const Duration(seconds: 1));
      expect(LongRunGuard.isActive, isTrue,
          reason: 'Der innere Aufruf hat den Dienst nicht gestartet und darf '
              'ihn dem äußeren nicht wegziehen.');
      expect(calls.where((c) => c == 'stop'), isEmpty);

      LongRunGuard.end(); // erst jetzt
      async.elapse(const Duration(seconds: 1));
    });
    expect(LongRunGuard.isActive, isFalse);
    expect(calls.last, 'stop');
  });

  test('a thrown operation still releases the service', () async {
    await expectLater(
      LongRunGuard.run('Test', () async => throw StateError('kaputt')),
      throwsA(isA<StateError>()),
    );
    expect(LongRunGuard.depth, 0,
        reason: 'Ein abgestürzter Lauf darf keine Meldung hinterlassen, die '
            'behauptet, es werde noch gearbeitet.');
    expect(LongRunGuard.isActive, isFalse);
  });

  test('an unpaired end cannot push the counter below zero', () {
    LongRunGuard.end();
    LongRunGuard.end();
    expect(LongRunGuard.depth, 0);
    LongRunGuard.begin();
    expect(LongRunGuard.depth, 1,
        reason: 'Sonst käme der nächste echte Lauf nie über null hinaus und '
            'bliebe ungeschützt.');
  });

  test('progress is only sent while the service runs, and not repeated', () {
    fakeAsync((async) {
      LongRunGuard.begin();
      LongRunGuard.progress('1 von 10'); // noch kein Dienst
      expect(calls, isEmpty);

      async.elapse(LongRunGuard.threshold + const Duration(seconds: 1));
      calls.clear();

      LongRunGuard.progress('2 von 10');
      LongRunGuard.progress('2 von 10'); // unverändert
      expect(calls.where((c) => c == 'update').length, 1,
          reason: 'Der Fortschritt feuert pro Mail-Block; unveränderten Text '
              'erneut zu senden wären tausende Kanalaufrufe.');
      LongRunGuard.end();
      async.elapse(const Duration(seconds: 1));
    });
  });
}
