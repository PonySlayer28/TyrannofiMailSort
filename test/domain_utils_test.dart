import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/utils/domain_utils.dart';

void main() {
  group('patternMatchesDomain', () {
    test('matches whole domain parts', () {
      expect(patternMatchesDomain('paypal', 'paypal.de'), isTrue);
      expect(patternMatchesDomain('paypal', 'mail.paypal.de'), isTrue);
      expect(patternMatchesDomain('paypal.de', 'mail.news.paypal.de'), isTrue);
      expect(patternMatchesDomain('bike-discount', 'bike-discount.de'), isTrue);
    });

    test('no longer swallows unrelated domains that merely contain it', () {
      // A rule from the folder "Tech/Auto" used to capture all of these.
      for (final d in [
        'meinauto.de',
        'autodoc.de',
        'atp-autoteile.de',
        'autohaus-hohenbrunn.de',
        'autoservice-portal.de',
      ]) {
        expect(patternMatchesDomain('auto', d), isFalse, reason: d);
      }
      // ... and "Gaming/Steam" captured these, including a team, not a game.
      for (final d in [
        'steamkeys.com',
        'steampowered.com',
        'truesteamachievements.com',
        'cbs-team.de',
      ]) {
        expect(patternMatchesDomain('steam', d), isFalse, reason: d);
      }
    });

    test('parts must be consecutive and in order', () {
      expect(patternMatchesDomain('paypal.de', 'paypal.co.de'), isFalse);
      expect(patternMatchesDomain('de.paypal', 'paypal.de'), isFalse);
    });

    test('empty input never matches', () {
      expect(patternMatchesDomain('', 'paypal.de'), isFalse);
      expect(patternMatchesDomain('paypal', ''), isFalse);
      expect(patternMatchesDomain('---', 'paypal.de'), isFalse);
    });
  });

  group('patternMatchesSender', () {
    test('matches on the domain', () {
      expect(patternMatchesSender('paypal', 'service@paypal.de'), isTrue);
      expect(patternMatchesSender('amazon', 'no-reply@amazon.de'), isTrue);
    });

    test('ignores the local part, so a lookalike address does not match', () {
      expect(patternMatchesSender('paypal', 'paypal@gmail.com'), isFalse);
      expect(patternMatchesSender('amazon', 'amazon.support@phish.ru'), isFalse);
    });
  });

  group('folderKey', () {
    test('ignores case and separators', () {
      expect(folderKey('Native-instruments'),
          equals(folderKey('NativeInstruments')));
      expect(folderKey('Bike-components'), equals(folderKey('BikeComponents')));
      expect(folderKey('iFixit'), equals(folderKey('Ifixit')));
    });

    test('keeps genuinely different names apart', () {
      expect(folderKey('Amazon'), isNot(equals(folderKey('Amazonas'))));
    });
  });
}
