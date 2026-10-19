// Pairing flat, app-generated folders with the hand-sorted folders they
// duplicate.
//
// Two eras of sorting left the same senders filed twice: `autoAssign` derives a
// flat folder straight from the sender domain (`amazon.de` → `Amazon`), while
// the hierarchical folders (`Shopping/Amazon`) were made by hand. Rule import
// then reads both and picks whichever the server listed first.

import '../models/results.dart';
import '../models/sort_rule.dart';
import 'domain_utils.dart';

class FolderMergePlan {
  /// Unambiguous pairs, safe to merge.
  final List<FolderMergePair> pairs;

  /// Flat folders matching more than one hierarchical folder — `Audible` fits
  /// both `Shopping/audible` and `Streaming/Audible`, and nothing in the folder
  /// names says which is meant. Left for the user to decide.
  final Map<String, List<String>> ambiguous;

  const FolderMergePlan({required this.pairs, required this.ambiguous});
}

/// Pair every flat folder with the hierarchical folder whose last path segment
/// it matches. Folders under a bracketed namespace (`[Gmail]/…`, `[Imap]/…`)
/// take no part: they are server views or leftovers, not categories.
FolderMergePlan planFolderMerges(List<FolderInfo> folders) {
  final counts = {for (final f in folders) f.name: f.count};
  final usable = folders.map((f) => f.name).where((n) => !n.startsWith('['));
  final flat = usable.where((n) => !n.contains('/')).toList();
  final hier = usable.where((n) => n.contains('/')).toList();

  final byLeaf = <String, List<String>>{};
  for (final h in hier) {
    byLeaf.putIfAbsent(folderKey(h.split('/').last), () => []).add(h);
  }

  final pairs = <FolderMergePair>[];
  final ambiguous = <String, List<String>>{};
  for (final f in flat) {
    final matches = byLeaf[folderKey(f)];
    if (matches == null || matches.isEmpty) continue;
    if (matches.length > 1) {
      ambiguous[f] = matches;
      continue;
    }
    pairs.add(FolderMergePair(
      source: f,
      target: matches.first,
      sourceCount: counts[f] ?? 0,
      targetCount: counts[matches.first] ?? 0,
    ));
  }
  pairs.sort((a, b) => b.sourceCount.compareTo(a.sourceCount));
  return FolderMergePlan(pairs: pairs, ambiguous: ambiguous);
}

/// A rule whose target folder is gone, and where it should point instead.
class RuleRepair {
  final SortRule rule;
  final String newTarget;
  const RuleRepair({required this.rule, required this.newTarget});
}

/// Find rules pointing at folders that no longer exist, and say where each
/// should point instead.
///
/// A merge moves a flat folder's mail into the categorised one and deletes the
/// flat folder — but the rules that named the flat folder stay behind. Applied
/// unchanged they recreate exactly the folder the merge just removed, quietly
/// undoing the cleanup. At this mailbox 76 of 520 rules were in that state
/// after merging 101 pairs.
///
/// The new target is found the same way [planFolderMerges] pairs folders: by
/// the last path segment. Ambiguity is left alone rather than guessed, and a
/// rule whose target simply never existed is not touched either — this repairs
/// the merge's own damage, it does not tidy up the user's typing.
List<RuleRepair> planRuleRepairs(
    List<SortRule> rules, List<String> existingFolders) {
  final usable = existingFolders.where((f) => !f.startsWith('['));
  final present = usable.toSet();
  final byLeaf = <String, List<String>>{};
  for (final h in usable.where((f) => f.contains('/'))) {
    byLeaf.putIfAbsent(folderKey(h.split('/').last), () => []).add(h);
  }

  final repairs = <RuleRepair>[];
  for (final r in rules) {
    if (r.moveTo.isEmpty || present.contains(r.moveTo)) continue;
    final matches = byLeaf[folderKey(r.moveTo)];
    if (matches == null || matches.length != 1) continue;
    repairs.add(RuleRepair(rule: r, newTarget: matches.first));
  }
  return repairs;
}
