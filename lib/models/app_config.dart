import 'mail_server.dart';
import 'sort_rule.dart';

/// Per-server configuration, mirroring gmail_organizer_config_<key>.json.
class AppConfig {
  final String serverKey;
  String email;
  String imapServer;
  int imapPort;
  List<SortRule> rules;

  /// Sort strictly by sender: the folder follows from the sender's domain and
  /// [rules] are not consulted at all.
  ///
  /// A switch rather than a replacement, because a hand-kept rule list is a
  /// perfectly good way to sort and this would silently discard it. Off by
  /// default; on, it makes the inbox follow the same law as a by-sender
  /// rebuild of the tree, so new mail lands where the existing mail sits.
  bool sortBySender;

  AppConfig({
    required this.serverKey,
    required this.email,
    required this.imapServer,
    required this.imapPort,
    required this.rules,
    this.sortBySender = false,
  });

  /// All valid rules (with a non-empty match pattern).
  List<SortRule> get allRules => rules.where((r) => r.isValid).toList();

  /// Only enabled valid rules.
  List<SortRule> get activeRules => allRules.where((r) => r.enabled).toList();

  factory AppConfig.defaults(String serverKey) {
    final srv = kServers[serverKey] ?? kServers['gmail']!;
    return AppConfig(
      serverKey: serverKey,
      email: '',
      imapServer: srv.imapServer,
      imapPort: srv.imapPort,
      rules: [],
    );
  }

  Map<String, dynamic> toJson() => {
        'email': email,
        'imap_server': imapServer,
        'imap_port': imapPort,
        'sort_rules': rules.map((r) => r.toJson()).toList(),
        'sort_by_sender': sortBySender,
        'cleanup': {},
      };

  factory AppConfig.fromJson(String serverKey, Map j) {
    final srv = kServers[serverKey] ?? kServers['gmail']!;
    return AppConfig(
      serverKey: serverKey,
      email: (j['email'] ?? '').toString(),
      imapServer: (j['imap_server'] ?? srv.imapServer).toString(),
      imapPort: (j['imap_port'] is int)
          ? j['imap_port']
          : int.tryParse('${j['imap_port']}') ?? srv.imapPort,
      rules: (j['sort_rules'] as List?)
              ?.whereType<Map>()
              .where((r) => r.containsKey('match') && r.containsKey('action'))
              .map((r) => SortRule.fromJson(r))
              .toList() ??
          [],
      sortBySender: j['sort_by_sender'] == true,
    );
  }
}
