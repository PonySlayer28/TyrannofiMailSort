import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../models/sort_rule.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});
  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final _storage = StorageService.instance;
  final _imap = ImapService.instance;
  final _app = AppState.instance;

  final _importProgress = ValueNotifier<OpProgress>(const OpProgress.idle());
  bool _importing = false;

  List<SortRule> get _rules => _app.config.allRules;

  @override
  void dispose() {
    _importProgress.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await _app.reload();
    setState(() {});
  }

  Future<void> _toggle(int i) async {
    await _storage.toggleRule(_app.serverKey, i);
    await _refresh();
  }

  Future<void> _delete(int i) async {
    await _storage.deleteRule(_app.serverKey, i);
    await _refresh();
  }

  Future<void> _dedup() async {
    final removed = await _storage.dedupRules(_app.serverKey);
    await _refresh();
    if (mounted) showSnack(context, '$removed duplicate rules removed.');
  }

  /// Drop the whole list.
  ///
  /// The warning names what actually changes, which is not the sorting: in
  /// sender mode no rule is read anyway, so today nothing moves differently.
  /// What goes is the way back — until now the switch could be flipped off and
  /// the hand-kept list was there unharmed.
  Future<void> _clearAll() async {
    final n = _app.config.rules.length;
    if (n == 0) return;
    final bySender = _app.config.sortBySender;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TF.surface,
        title: Text('Delete all $n rules?'),
        content: Text(
          bySender
              ? 'Sorting is currently by sender — rules are not read anyway. '
                  'Deleting them changes nothing about what the app does.\n\n'
                  'What you lose is the way back: as long as the list exists, '
                  'sender mode can be turned off and the rules are still there '
                  'unchanged. After deletion, they are gone.'
              : 'Sorting is currently by rules. Without them, every mail stays '
                  'in the inbox until sender mode is turned on.\n\n'
                  'This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete all',
                style: TextStyle(color: TF.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final removed = await _storage.clearRules(_app.serverKey);
    await _refresh();
    if (mounted) showSnack(context, '$removed rules deleted.');
  }

  Future<void> _addDialog() async {
    final fromCtl = TextEditingController();
    final folderCtl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New rule'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: fromCtl,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Sender contains', hintText: 'e.g. paypal'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: folderCtl,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Target folder', hintText: 'e.g. Paypal'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (result == true) {
      final from = fromCtl.text.trim();
      final folder = folderCtl.text.trim();
      if (from.isEmpty || folder.isEmpty) return;
      final err = await _storage.addRule(_app.serverKey, '', from, folder);
      await _refresh();
      if (mounted && err != null) showSnack(context, err, error: true);
    }
  }

  Future<void> _importFromFolders() async {
    if (!_app.hasCredentials) {
      showSnack(context, 'Please set up account + password first.',
          error: true);
      return;
    }
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final folderDomains = await _imap.scanFoldersForRuleImport(
          _app.config, _app.password,
          onProgress: (p) => _importProgress.value = p);
      final added = await _storage.importRulesFromFolders(
          _app.serverKey, folderDomains,
          sampleSize: ImapService.defaultRuleSampleSize);
      await _refresh();
      if (mounted) {
        showSnack(context,
            added > 0 ? '$added rule(s) imported from folders.' : 'No new rules found — everything already covered.');
      }
    } catch (e) {
      _importProgress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = _rules;
    return Scaffold(
      appBar: tfAppBar(
        'RULES',
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: 'Remove duplicates',
            onPressed: _dedup,
          ),
          // Only there when there is something to delete, so the destructive
          // button is absent from an empty list rather than merely useless.
          if (rules.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, color: TF.danger),
              tooltip: 'Delete all rules',
              onPressed: _clearAll,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: TF.accent,
        foregroundColor: TF.bg,
        onPressed: _addDialog,
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Already sorted your mailbox by hand? This imports your '
                    'existing folder structure as rules — for every sender '
                    'that appears more than once in a folder.',
                    style: TextStyle(color: TF.text2, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.folder_copy_outlined),
                    label: const Text('Import from existing folders'),
                    onPressed: _importing ? null : _importFromFolders,
                  ),
                  ValueListenableBuilder<OpProgress>(
                    valueListenable: _importProgress,
                    builder: (_, p, __) => Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ProgressPanel(p),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (rules.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyState(
                icon: Icons.rule,
                message: 'No rules.\nTap + to add one or\ncreate them automatically via inbox scan.'),
            )
          else
            ...rules.asMap().entries.map((e) => _ruleTile(e.key, e.value)),
        ],
      ),
    );
  }

  Widget _ruleTile(int i, SortRule r) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: Switch(
          value: r.enabled,
          activeThumbColor: TF.accent,
          onChanged: (_) => _toggle(i),
        ),
        title: Text('"${r.matchFrom}"',
            style: TextStyle(
                fontSize: 14,
                color: r.enabled ? TF.text : TF.text2,
                fontWeight: FontWeight.w600)),
        subtitle: Row(
          children: [
            const Icon(Icons.arrow_forward, size: 12, color: TF.text2),
            const SizedBox(width: 4),
            Flexible(
              child: Text(r.moveTo,
                  style: const TextStyle(color: TF.accent2, fontSize: 12)),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: TF.danger),
          onPressed: () => _delete(i),
        ),
      ),
    );
  }
}
