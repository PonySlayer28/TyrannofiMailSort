/// A single sort rule: match sender substring → move to folder.
///
/// JSON layout matches gmail_app.py exactly so configs are interchangeable:
///   {"name": "...", "match": {"from": "..."}, "action": {"move_to": "..."}, "enabled": true}
class SortRule {
  String name;
  String matchFrom;
  String moveTo;
  bool enabled;

  SortRule({
    required this.name,
    required this.matchFrom,
    required this.moveTo,
    this.enabled = true,
  });

  factory SortRule.fromJson(Map<dynamic, dynamic> j) {
    final match = (j['match'] as Map?) ?? const {};
    final action = (j['action'] as Map?) ?? const {};
    return SortRule(
      name: (j['name'] ?? '').toString(),
      matchFrom: (match['from'] ?? '').toString(),
      moveTo: (action['move_to'] ?? '').toString(),
      enabled: j['enabled'] == null ? true : j['enabled'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'match': {'from': matchFrom},
        'action': {'move_to': moveTo},
        'enabled': enabled,
      };

  /// Only rules with a non-empty match pattern are valid, mirroring
  /// get_all_rules() which requires "match" and "action" keys.
  bool get isValid => matchFrom.isNotEmpty;
}
