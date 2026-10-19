import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/models/mail_server.dart';

void main() {
  group('which provider the app opens after a restart', () {
    test('a remembered provider is used', () {
      expect(validServerKey('yahoo'), 'yahoo');
    });

    test('each of the eight providers comes back unchanged', () {
      for (final key in kServers.keys) {
        expect(validServerKey(key), key);
      }
    });

    test('without a remembered provider it starts at Gmail', () {
      expect(validServerKey(null), 'gmail');
    });

    // A key from an older version must not reach the selection list: the
    // dropdown crashes when its value is missing there, and the provider
    // switch as a whole would be broken.
    test('a provider that no longer exists falls back to Gmail', () {
      expect(validServerKey('altavista'), 'gmail');
    });

    test('the empty string is not a provider either', () {
      expect(validServerKey(''), 'gmail');
    });
  });
}
