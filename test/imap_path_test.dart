import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/utils/imap_path.dart';

void main() {
  group('encodeMailboxPath', () {
    test('leaves a plain ASCII name alone', () {
      expect(encodeMailboxPath('Amazon', '/'), 'Amazon');
      expect(encodeMailboxPath('Shopping/Amazon', '/'), 'Shopping/Amazon');
      expect(encodeMailboxPath('INBOX', '/'), 'INBOX');
    });

    test('writes the umlaut that broke the drafts folder', () {
      // The one folder both bulk runs left unfinished: the server answered
      // `BAD Could not parse command` because the ü went out raw.
      expect(encodeMailboxPath('Entwürfe', '/'), 'Entw&APw-rfe');
    });

    test('doubles a literal ampersand, which otherwise starts an escape', () {
      expect(encodeMailboxPath('AT&T', '/'), 'AT&-T');
    });

    test('encodes a parent segment too, not just the last one', () {
      // `Mailbox.encode` stops at the final separator, so a category with an
      // umlaut would have gone over the wire raw while its child was encoded.
      expect(encodeMailboxPath('Bücher/Amazon', '/'), 'B&APw-cher/Amazon');
      expect(encodeMailboxPath('Bücher/Käse', '/'), 'B&APw-cher/K&AOQ-se');
    });

    test('respects a server that separates with something other than /', () {
      expect(encodeMailboxPath('Bücher.Amazon', '.'), 'B&APw-cher.Amazon');
      // With `.` as the separator a slash is an ordinary character.
      expect(encodeMailboxPath('a/b', '.'), 'a/b');
    });

    test('survives the round trip back to the name we display', () {
      for (final name in ['Entwürfe', 'Bücher/Käse', 'AT&T', 'Amazon']) {
        final encoded = encodeMailboxPath(name, '/');
        final box = Mailbox(
          encodedName: encoded,
          encodedPath: encoded,
          flags: [],
          pathSeparator: '/',
        );
        expect(box.path, name);
      }
    });
  });

  group('encodeMailboxParents', () {
    test('leaves the last segment for the caller to encode', () {
      expect(encodeMailboxParents('Bücher/Käse', '/'), 'B&APw-cher/Käse');
      expect(encodeMailboxParents('Entwürfe', '/'), 'Entwürfe');
      expect(encodeMailboxParents('Shopping/Amazon', '/'), 'Shopping/Amazon');
    });
  });

  // The reason `encodeMailboxParents` exists at all. `createMailbox`,
  // `renameMailbox`, `uidMove` and `uidCopy` run their own encoding pass over
  // the whole path, and we rely on that pass touching nothing but the final
  // segment — otherwise our already-encoded parents would be encoded a second
  // time and `B&APw-cher` would arrive as `B&-APw-cher`.
  //
  // That is `enough_mail` behaviour, not ours, so it is pinned here: an upgrade
  // that starts encoding the whole path fails this test instead of quietly
  // mangling every folder with an umlaut above it.
  group('the enough_mail behaviour these two rest on', () {
    test('Mailbox.encode touches only the segment after the last separator',
        () {
      expect(Mailbox.encode('Bücher/Käse', '/'), 'Bücher/K&AOQ-se');
      expect(Mailbox.encode('Entwürfe', '/'), 'Entw&APw-rfe');
    });

    test('so an encoded parent passes through its pass unharmed', () {
      final ours = encodeMailboxParents('Bücher/Käse', '/');
      expect(Mailbox.encode(ours, '/'), encodeMailboxPath('Bücher/Käse', '/'));
    });
  });
}
