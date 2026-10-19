import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../utils/folder_merge.dart';
import '../widgets/common.dart';

class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({super.key});
  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _storage = StorageService.instance;

  final _sortProgress = ValueNotifier<OpProgress>(const OpProgress.idle());
  final _dupeProgress = ValueNotifier<OpProgress>(const OpProgress.idle());
  bool _busy = false;

  @override
  void dispose() {
    _sortProgress.dispose();
    _dupeProgress.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Refuse to sort while rules name folders that no longer exist.
  ///
  /// Such a rule recreates the folder a merge deleted, so sorting now undoes
  /// the merge that came before it — silently, and in proportion to how well
  /// the cleanup went. The repair is offered here rather than only pointed at:
  /// being sent to another screen to fix a problem the app already understands
  /// is how people end up skipping it.
  ///
  /// Returns true when sorting may go ahead.
  Future<bool> _clearedForSort() async {
    // Sorting by sender never reads a rule, so a rule naming a deleted folder
    // cannot recreate it. Checking anyway would block on a question that has
    // stopped mattering.
    if (_app.config.sortBySender) return true;
    final List<RuleRepair> repairs;
    // The check needs the folder list, which after a merge is no longer cached
    // and takes about a minute to fetch. Say so: an unlabelled dead button for
    // that long reads as a broken app, and the next thing tried is a restart.
    _sortProgress.value = const OpProgress().running('Checking rules...');
    try {
      repairs = await _imap.pendingRuleRepairs(_app.config, _app.password);
    } catch (_) {
      return true; // Unreachable server: let sortInbox report the real error.
    }
    if (repairs.isEmpty || !mounted) return true;
    _sortProgress.value = const OpProgress.idle();
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: Text(
            '${counted(repairs.length, 'rule points', 'rules point')} '
            'to nothing'),
        content: const Text(
          'They name folders that no longer exist — usually because they '
          'were merged.\n\n'
          'Sorting would recreate those folders and undo the merge.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, 'repair'),
            child: const Text('Repair and sort'),
          ),
        ],
      ),
    );
    if (choice != 'repair' || !mounted) return false;
    final changed = await _storage.applyRuleRepairs(_app.serverKey, repairs);
    if (mounted) {
      showSnack(context, '${counted(changed, 'rule', 'rules')} redirected.');
    }
    return true;
  }

  Future<void> _sort() => _run(() async {
        if (!await _clearedForSort()) return;
        try {
          await _imap.sortInbox(_app.config, _app.password,
              onProgress: (p) => _sortProgress.value = p);
        } catch (e) {
          // sortInbox already reports an error progress; keep it visible.
          if (_sortProgress.value.status != 'error') {
            _sortProgress.value = OpProgress(status: 'error', message: '$e');
          }
        }
      });

  Future<void> _findDupes() => _run(() async {
        try {
          final res = await _imap.findDupes(_app.config, _app.password,
              onProgress: (p) => _dupeProgress.value = p);
          _app.setDupes(res);
          setState(() {});
        } catch (e) {
          _dupeProgress.value = OpProgress(status: 'error', message: '$e');
        }
      });

  Future<void> _deleteDupes() async {
    final dupes = _app.dupes;
    if (dupes == null || dupes.groups.isEmpty) return;
    final confirm = await _confirm(
        'Delete duplicates?',
        '${dupes.totalDupes} copies will be deleted. One email per '
            'group is kept.');
    if (confirm != true) return;
    _run(() async {
      try {
        await _imap.deleteDupes(_app.config, _app.password, dupes,
            onProgress: (p) => _dupeProgress.value = p);
        _app.setDupes(DupeResult.empty());
        setState(() {});
      } catch (e) {
        _dupeProgress.value = OpProgress(status: 'error', message: '$e');
      }
    });
  }

  Future<bool?> _confirm(String title, String msg) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(msg),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: TF.danger),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final dupes = _app.dupes;
    return Scaffold(
      appBar: tfAppBar('SORT & CLEAN UP'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          const SectionLabel('Sorting'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _app.config.sortBySender
                        ? 'Sorts by sender: one folder per sender domain, '
                            'missing ones are created. The '
                            '${_app.config.allRules.length} rules are ignored. '
                            'Progress is saved and can be resumed.'
                        : '${_app.config.activeRules.length} active rules '
                            'are applied to the INBOX. Progress is saved '
                            'and can be resumed.',
                    style: const TextStyle(color: TF.text2, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.sort),
                    label: const Text('Run sort'),
                    onPressed: _busy ? null : _sort,
                  ),
                  ValueListenableBuilder<OpProgress>(
                    valueListenable: _sortProgress,
                    builder: (_, p, __) => Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ProgressPanel(p),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SectionLabel('Duplicates'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Finds real duplicates across all folders (by Message-ID '
                    'or fingerprint).',
                    style: TextStyle(color: TF.text2, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.content_copy),
                          label: const Text('Find'),
                          onPressed: _busy ? null : _findDupes,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.delete_sweep, color: TF.danger),
                          label: const Text('Delete',
                              style: TextStyle(color: TF.danger)),
                          style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: TF.danger)),
                          onPressed: (_busy ||
                                  dupes == null ||
                                  dupes.groups.isEmpty)
                              ? null
                              : _deleteDupes,
                        ),
                      ),
                    ],
                  ),
                  ValueListenableBuilder<OpProgress>(
                    valueListenable: _dupeProgress,
                    builder: (_, p, __) => Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: ProgressPanel(p),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (dupes != null && dupes.groups.isNotEmpty) ...[
            const SectionLabel('Found groups'),
            ...dupes.groups.take(100).map(_dupeTile),
          ],
        ],
      ),
    );
  }

  Widget _dupeTile(DupeGroup g) {
    return Card(
      child: ListTile(
        title: Text(g.subject.isEmpty ? '(no subject)' : g.subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text(
            '${g.from}\n${g.locations.map((l) => l.folder).toSet().join(", ")}',
            style: const TextStyle(color: TF.text2, fontSize: 11)),
        isThreeLine: true,
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: TF.surface2,
          child: Text('${g.count}',
              style: const TextStyle(color: TF.danger, fontSize: 12)),
        ),
      ),
    );
  }
}
