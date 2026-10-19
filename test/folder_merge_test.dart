import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/models/results.dart';
import 'package:tyrannofi_app/models/sort_rule.dart';
import 'package:tyrannofi_app/utils/folder_merge.dart';

FolderInfo f(String n, [int c = 1]) => FolderInfo(name: n, count: c);

SortRule r(String from, String to) =>
    SortRule(name: '\$from -> \$to', matchFrom: from, moveTo: to);

void main() {
  test('pairs flat app folders with hand-sorted hierarchical ones', () {
    final plan = planFolderMerges([
      f('Amazon', 983), f('Shopping/Amazon', 1852),
      f('Native-instruments'), f('Musik/NativeInstruments'),
      f('Bike-components'), f('Sport/BikeComponents'),
      f('Ifixit'), f('Tech/iFixit'),
    ]);
    expect(plan.pairs.map((p) => '${p.source}>${p.target}'), [
      'Amazon>Shopping/Amazon',
      'Native-instruments>Musik/NativeInstruments',
      'Bike-components>Sport/BikeComponents',
      'Ifixit>Tech/iFixit',
    ]);
    expect(plan.pairs.first.sourceCount, 983);
    expect(plan.pairs.first.targetCount, 1852);
  });

  test('refuses to guess when a flat folder fits two categories', () {
    final plan = planFolderMerges([
      f('Audible'), f('Shopping/audible'), f('Streaming/Audible'),
    ]);
    expect(plan.pairs, isEmpty);
    expect(plan.ambiguous['Audible'], ['Shopping/audible', 'Streaming/Audible']);
  });

  test('leaves bracketed server namespaces alone', () {
    final plan = planFolderMerges([
      f('Flaconi'), f('Shopping/Flaconi'),
      f('[Google Mail]/Papierkorb/Flaconi'), f('[Imap]/Papierkorb'),
    ]);
    expect(plan.pairs.single.target, 'Shopping/Flaconi');
  });

  test('folders with no counterpart are not touched', () {
    final plan = planFolderMerges([f('Wichtel-o-mat'), f('Shopping/Lego')]);
    expect(plan.pairs, isEmpty);
    expect(plan.ambiguous, isEmpty);
  });

  test('repoints rules left pointing at a folder the merge deleted', () {
    final repairs = planRuleRepairs(
      [r('amazon', 'Amazon'), r('mut', 'Mut')],
      ['Shopping/Amazon', 'Tech/MuT'],
    );
    expect(repairs.map((x) => '${x.rule.moveTo}>${x.newTarget}'),
        ['Amazon>Shopping/Amazon', 'Mut>Tech/MuT']);
  });

  test('leaves rules whose target still exists alone', () {
    final repairs = planRuleRepairs(
      [r('amazon', 'Shopping/Amazon'), r('lego', 'Shopping/Lego')],
      ['Shopping/Amazon', 'Shopping/Lego'],
    );
    expect(repairs, isEmpty);
  });

  test('refuses to guess a new target when two folders would fit', () {
    final repairs = planRuleRepairs(
      [r('audible', 'Audible')],
      ['Shopping/audible', 'Streaming/Audible'],
    );
    expect(repairs, isEmpty);
  });

  test('leaves a rule alone when no folder matches its lost target', () {
    final repairs = planRuleRepairs(
      [r('tippfehler', 'Shoping/Amazn')],
      ['Shopping/Amazon'],
    );
    expect(repairs, isEmpty);
  });
}
