import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../utils/folder_merge.dart';
import '../widgets/common.dart';

/// Folds the flat folders the app generated from sender domains into the
/// hand-sorted hierarchical folders that duplicate them.
///
/// Deliberately one pair at a time: a merge cannot be undone from the server
/// side, so each one is its own decision with its own backup file.
class MergeScreen extends StatefulWidget {
  final List<FolderInfo> folders;
  const MergeScreen({super.key, required this.folders});

  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends State<MergeScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _storage = StorageService.instance;
  final _progress = ValueNotifier<OpProgress>(const OpProgress.idle());

  late final FolderMergePlan _plan = planFolderMerges(widget.folders);
  final _done = <String, MergeResult>{};
  String? _busy;
  bool _batch = false;
  bool _stop = false;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _merge(FolderMergePair pair) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: const Text('Merge?'),
        content: Text(
          '${pair.sourceCount} emails from "${pair.source}" will move to '
          '"${pair.target}". Then "${pair.source}" will be deleted.\n\n'
          'Message-IDs are backed up beforehand — that is the only trace '
          'of the old assignment. Neither the app nor Gmail can undo this.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Merge',
                style: TextStyle(color: TF.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = pair.source);
    try {
      final ids = await _imap.collectMessageIds(
          _app.config, _app.password, pair.source,
          onProgress: (p) => _progress.value = p);
      final backup =
          await _storage.saveMergeBackup(_app.serverKey, pair.source, ids);
      debugPrint('[TyrannoFi] Backup: $backup (${ids.length} IDs)');

      final res = await _imap.mergeFolder(
          _app.config, _app.password, pair.source, pair.target,
          onProgress: (p) => _progress.value = p);
      if (!mounted) return;
      setState(() => _done[pair.source] = res);
      _progress.value = OpProgress(
          status: res.complete ? 'done' : 'error',
          message: res.complete
              ? '${res.moved} emails moved, backup: $backup'
              : 'Only ${res.moved} of ${res.total} moved — '
                  '"${pair.source}" kept.');
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _mergeAll() async {
    final pending =
        _plan.pairs.where((p) => !_done.containsKey(p.source)).toList();
    if (pending.isEmpty) return;
    final mails = pending.fold<int>(0, (s, p) => s + p.sourceCount);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: Text('Merge ${pending.length} folders?'),
        content: Text(
          'About $mails emails will move to their topic folders, '
          '${pending.length} flat folders will be deleted afterwards.\n\n'
          'Each folder is backed up before processing; if a backup cannot '
          'be written, the folder is left untouched.\n\n'
          'The run can be cancelled at any time — it stops at the next '
          'folder boundary, not in the middle of one.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Merge all',
                style: TextStyle(color: TF.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _batch = true;
      _stop = false;
    });
    try {
      final results = await _imap.mergeFolders(
        _app.config,
        _app.password,
        pending,
        shouldStop: () => _stop,
        onSnapshot: (folder, ids) async {
          final path =
              await _storage.saveMergeBackup(_app.serverKey, folder, ids);
          debugPrint('[TyrannoFi] Backup: $path (${ids.length} IDs)');
        },
        onPair: (done, total, last) {
          if (last != null && mounted) {
            setState(() => _done[last.source] = last);
          }
        },
        onProgress: (p) => _progress.value = p,
      );
      final okCount = results.where((r) => r.complete).length;
      final failed = results.length - okCount;
      _progress.value = OpProgress(
          status: failed == 0 ? 'done' : 'error',
          message: '$okCount of ${pending.length} merged'
              '${failed > 0 ? ", $failed skipped or incomplete" : ""}'
              '${_stop ? " — cancelled" : ""}.');
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _batch = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        _plan.pairs.where((p) => !_done.containsKey(p.source)).toList();
    return Scaffold(
      appBar: tfAppBar('DUPLICATES'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _intro(pending.length),
          if (pending.isNotEmpty) _batchBar(pending),
          ValueListenableBuilder<OpProgress>(
            valueListenable: _progress,
            builder: (_, p, __) => p.status == 'idle'
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ProgressPanel(p)),
          ),
          if (_plan.ambiguous.isNotEmpty) _ambiguousCard(),
          for (final p in _plan.pairs) _pairTile(p),
          if (_plan.pairs.isEmpty)
            const EmptyState(
                icon: Icons.done_all,
                message: 'No clear duplicates found.'),
          if (_app.serverKey == 'gmail') _gmailHiddenLabelsNote(),
        ],
      ),
    );
  }

  Widget _batchBar(List<FolderMergePair> pending) {
    final mails = pending.fold<int>(0, (s, p) => s + p.sourceCount);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _batch
          ? Row(
              children: [
                Expanded(
                  child: Text('${_done.length} of ${_plan.pairs.length} done',
                      style: const TextStyle(color: TF.text2, fontSize: 12)),
                ),
                OutlinedButton(
                  onPressed: _stop ? null : () => setState(() => _stop = true),
                  child: Text(_stop ? 'Stopping...' : 'Cancel'),
                ),
              ],
            )
          : SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.playlist_add_check, size: 18),
                label: Text(
                    'Merge all ${pending.length}  (~$mails emails)'),
                onPressed: _busy != null ? null : _mergeAll,
              ),
            ),
    );
  }

  Widget _intro(int pending) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '$pending pending. Each merge moves the emails from the flat '
          'folder into the topic folder and deletes the flat one. Nothing '
          'goes through the inbox, no email loses its topic.',
          style: const TextStyle(color: TF.text2, fontSize: 12),
        ),
      );

  /// Gmail lets a label be hidden from IMAP, and a hidden label is simply not
  /// there for this app — no cleverness reaches it, so the only honest move is
  /// to say so. At this mailbox seven labels were hidden that way, and their
  /// flat counterparts kept looking like folders without a partner.
  Widget _gmailHiddenLabelsNote() => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.visibility_off, size: 15, color: TF.text2),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Missing a pair that exists in Gmail? Labels with "Show in '
                'IMAP" turned off are invisible to this app — even as '
                'targets. Check in Gmail on desktop under '
                'Settings → Labels.',
                style: const TextStyle(color: TF.text2, fontSize: 11)
                    .copyWith(height: 1.4),
              ),
            ),
          ],
        ),
      );

  Widget _ambiguousCard() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TF.surface,
          border: Border.all(color: TF.danger),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ambiguous — please decide manually',
                style:
                    TextStyle(color: TF.danger, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final e in _plan.ambiguous.entries)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('"${e.key}" matches ${e.value.join("  and  ")}',
                    style: const TextStyle(color: TF.text2, fontSize: 12)),
              ),
          ],
        ),
      );

  Widget _pairTile(FolderMergePair p) {
    final res = _done[p.source];
    final busy = _busy == p.source;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TF.surface,
        border: Border.all(color: res != null ? TF.ok : TF.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p.source}  (${p.sourceCount})',
                    style: const TextStyle(color: TF.text)),
                Text('→ ${p.target}  (${p.targetCount})',
                    style: const TextStyle(color: TF.text2, fontSize: 12)),
                if (res != null)
                  Text(
                    res.complete
                        ? '${res.moved} moved'
                            '${res.sourceDeleted ? ", folder deleted" : ""}'
                        : '${res.moved}/${res.total} — folder kept',
                    style: TextStyle(
                        color: res.complete ? TF.ok : TF.danger, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (res == null)
            busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : OutlinedButton(
                    onPressed:
                        (_busy != null || _batch) ? null : () => _merge(p),
                    child: const Text('Merge'),
                  ),
        ],
      ),
    );
  }
}
