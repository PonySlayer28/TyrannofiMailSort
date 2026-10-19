import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/models/app_config.dart';
import 'package:tyrannofi_app/models/sort_rule.dart';

void main() {
  AppConfig cfg({bool bySender = false}) => AppConfig(
        serverKey: 'gmail',
        email: 'x@example.com',
        imapServer: 'imap.example.com',
        imapPort: 993,
        rules: [
          SortRule(name: 'r', matchFrom: 'amazon', moveTo: 'Shopping/Amazon'),
        ],
        sortBySender: bySender,
      );

  group('sortBySender survives a save and load', () {
    test('true round-trips', () {
      final j = cfg(bySender: true).toJson();
      expect(AppConfig.fromJson('gmail', j).sortBySender, isTrue);
    });

    test('false round-trips', () {
      final j = cfg().toJson();
      expect(AppConfig.fromJson('gmail', j).sortBySender, isFalse);
    });

    test('a config written before the switch existed reads as off', () {
      // Every stored config predates the field. Defaulting it to on would
      // change how an existing mailbox sorts without anyone asking for it.
      final old = {
        'email': 'x@example.com',
        'imap_server': 'imap.example.com',
        'imap_port': 993,
        'sort_rules': [],
      };
      expect(AppConfig.fromJson('gmail', old).sortBySender, isFalse);
    });

    test('the rules are kept, not discarded, when sorting by sender', () {
      // The switch decides which law applies; it does not delete the other one,
      // so turning it back off restores the previous behaviour intact.
      final back = AppConfig.fromJson('gmail', cfg(bySender: true).toJson());
      expect(back.rules, hasLength(1));
      expect(back.rules.first.moveTo, 'Shopping/Amazon');
    });
  });
}
