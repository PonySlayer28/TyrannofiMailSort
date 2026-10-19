import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/models/mail_server.dart';

void main() {
  group('welchen Anbieter die App nach einem Neustart wieder aufschlägt', () {
    test('ein gemerkter Anbieter wird genommen', () {
      expect(validServerKey('yahoo'), 'yahoo');
    });

    test('jeder der acht Anbieter kommt unverändert zurück', () {
      for (final key in kServers.keys) {
        expect(validServerKey(key), key);
      }
    });

    test('ohne gemerkten Anbieter beginnt es bei Gmail', () {
      expect(validServerKey(null), 'gmail');
    });

    // Ein Schlüssel aus einer älteren Fassung darf die Auswahlliste nicht
    // erreichen: der Dropdown bricht ab, wenn sein Wert dort fehlt, und dann
    // wäre der Anbieterwechsel als Ganzes hin.
    test('ein Anbieter, den es nicht mehr gibt, fällt auf Gmail zurück', () {
      expect(validServerKey('altavista'), 'gmail');
    });

    test('auch die leere Zeichenkette ist kein Anbieter', () {
      expect(validServerKey(''), 'gmail');
    });
  });
}
