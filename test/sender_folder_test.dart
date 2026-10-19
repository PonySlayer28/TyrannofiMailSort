import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/utils/domain_utils.dart';

/// [senderFolder] decides where every single mail goes in a strict-by-sender
/// run. There is no rule list to correct it afterwards and no undo on the
/// server, so its edges are worth pinning down.
void main() {
  group('senderFolder', () {
    test('one folder per sender domain, whatever the subdomain', () {
      expect(senderFolder('service@amazon.de'), 'Amazon');
      expect(senderFolder('noreply@mail.amazon.de'), 'Amazon');
      expect(senderFolder('x@news.marketing.amazon.de'), 'Amazon');
    });

    test('the local part never reaches the folder name', () {
      // A sender calling itself paypal@gmail.com belongs to Gmail, not PayPal.
      expect(senderFolder('paypal@gmail.com'), 'Gmail');
    });

    test('every address at one domain lands in the same folder', () {
      // The core requirement: info@ and customer@ at the same
      // company belong together. Only the domain names the folder, so no
      // department, no ticket system and no campaign id can split a sender
      // across folders.
      const same = [
        'info@finanzguru.de',
        'customer@finanzguru.de',
        'no-reply@finanzguru.de',
        'support+ticket-4711@finanzguru.de',
        'bounce@mail.finanzguru.de',
        'news@newsletter.finanzguru.de',
      ];
      for (final a in same) {
        expect(senderFolder(a), 'Finanzguru', reason: a);
      }
    });

    test('the folder name is never a path — no category above it', () {
      // A category would need a slash; there is none to give.
      for (final a in ['x@finanzguru.de', 'x@amazon.de', 'x@asos.co.uk']) {
        expect(senderFolder(a), isNot(contains('/')), reason: a);
      }
    });

    test('country variants of one brand share a folder', () {
      expect(senderFolder('a@amazon.de'), senderFolder('b@amazon.com'));
    });

    test('hyphenated domains keep their hyphen', () {
      expect(senderFolder('info@bike-discount.de'), 'Bike-discount');
      expect(senderFolder('x@plugin-alliance.com'), 'Plugin-alliance');
    });

    test('a two-part country suffix does not swallow the name', () {
      // Taking the last two labels put every one of these into a folder
      // called "Co" — a junk drawer that grows with every British shop.
      expect(senderFolder('x@amazon.co.uk'), 'Amazon');
      expect(senderFolder('x@asos.co.uk'), 'Asos');
      expect(senderFolder('x@shop.com.au'), 'Shop');
      expect(senderFolder('x@rakuten.co.jp'), 'Rakuten');
      expect(senderFolder('x@mail.news.asos.co.uk'), 'Asos');
    });

    test('a plain two-label domain still keeps its name', () {
      // The country-suffix rule must not fire here: co.de is not a suffix.
      expect(senderFolder('x@co.de'), 'Co');
      expect(senderFolder('x@paypal.de'), 'Paypal');
    });

    test('an unusable sender yields null, not a junk folder', () {
      // These go to the INBOX instead — a folder named after a broken header
      // would be worse than an obvious pile of work.
      expect(senderFolder(''), isNull);
      expect(senderFolder('no-at-sign-at-all'), isNull);
      expect(senderFolder('someone@localhost'), isNull);
      expect(senderFolder('someone@'), isNull);
    });

    test('a From header cannot smuggle a path separator into the tree', () {
      // Without stripping, this would create the subfolder Evil/sub.
      expect(senderFolder(r'x@evil/sub.de'), 'Evilsub');
      expect(senderFolder(r'x@a\b.de'), 'Ab');
    });

    test('a From header cannot smuggle IMAP wildcards or control characters',
        () {
      expect(senderFolder('x@we*rd.de'), 'Werd');
      expect(senderFolder('x@qu"ote.de'), 'Quote');
      expect(senderFolder('x@tab\tbed.de'), 'Tabbed');
    });

    test('letters outside ASCII survive', () {
      expect(senderFolder('x@müller.de'), 'Müller');
    });

    test('case in the address does not reach the folder name', () {
      expect(senderFolder('X@AMAZON.DE'), 'Amazon');
    });
  });

  group('isReservedMailboxName', () {
    test('catches the drafts folder that slipped into a by-sender run', () {
      // The live case: a plain top-level "Entwürfe" carried no \Drafts flag,
      // so only the name check stands between it and a bulk sort or delete.
      expect(isReservedMailboxName('Entwürfe'), isTrue);
      expect(isReservedMailboxName('entwürfe'), isTrue);
      expect(isReservedMailboxName('Entwuerfe'), isTrue);
      expect(isReservedMailboxName('Drafts'), isTrue);
    });

    test('catches sent, trash, spam and outbox in both languages', () {
      for (final n in [
        'Gesendet', 'Sent', 'Sent Items',
        'Papierkorb', 'Trash', 'Bin',
        'Junk', 'Spam',
        'Postausgang', 'Outbox',
      ]) {
        expect(isReservedMailboxName(n), isTrue, reason: n);
      }
    });

    test('still catches them after the tree was pushed aside', () {
      // "Alle Ordner beiseiteschieben" turns Entwürfe into Alt/Entwürfe.
      expect(isReservedMailboxName('Alt/Entwürfe'), isTrue);
      expect(isReservedMailboxName('Alt/Gesendet'), isTrue);
    });

    test('leaves ordinary sender folders alone', () {
      for (final n in ['Amazon', 'Paypal', 'Finanzguru', 'Play-asia', 'Xing']) {
        expect(isReservedMailboxName(n), isFalse, reason: n);
      }
    });
  });

  group('isProtectedMailboxPath', () {
    test('keeps the reset out of the boxes that would ruin it', () {
      // Diese Liste ist die Sicherheitszusage von "Alles zurück in den
      // Posteingang". Jeder Eintrag hier steht für einen anderen Weg, ein
      // Postfach zu zerstören.
      for (final p in [
        'INBOX', 'inbox', // Verschieben in sich selbst = Kopie + Löschen
        '[Gmail]/Alle Nachrichten', // Verschieben heraus = Papierkorb
        '[Google Mail]/Alle Nachrichten',
        '[Imap]/Gesendet',
        'Entwürfe', 'Gesendet', 'Papierkorb', 'Spam', // eigener Mailfluss
      ]) {
        expect(isProtectedMailboxPath(p), isTrue, reason: p);
      }
    });

    test('lets ordinary sender folders through', () {
      for (final p in ['Amazon', 'Paypal', 'Play-asia', 'Shopping/Amazon']) {
        expect(isProtectedMailboxPath(p), isFalse, reason: p);
      }
    });
  });

  group('safeFolderSegment', () {
    test('strips what a path or a command would read as structure', () {
      expect(safeFolderSegment('a/b'), 'ab');
      expect(safeFolderSegment('a*b'), 'ab');
      expect(safeFolderSegment('  Amazon  '), 'Amazon');
    });

    test('leaves an ordinary name untouched', () {
      expect(safeFolderSegment('Bike-discount'), 'Bike-discount');
    });
  });
}
