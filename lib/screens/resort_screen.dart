import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Rebuilds the whole folder tree strictly by sender: one flat folder per
/// sender domain, nothing else.
///
/// Deliberately not "delete every label, then sort". Without a label a mail
/// sits only in All Mail, and moving it out of there is not a label change but
/// a trip to the trash — so the tree is rebuilt folder by folder instead, and
/// no mail is ever without a place. Mails whose sender yields no domain go to
/// the INBOX: one agreed starting point for everything that could not be
/// placed, rather than a remnant left in a folder that is about to go.
class ResortScreen extends StatefulWidget {
  const ResortScreen({super.key});

  @override
  State<ResortScreen> createState() => _ResortScreenState();
}

class _ResortScreenState extends State<ResortScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _storage = StorageService.instance;
  final _progress = ValueNotifier<OpProgress>(const OpProgress.idle());

  List<String>? _folders;
  final _done = <String, ResortResult>{};

  /// Folders an earlier, interrupted run already finished. Read back from the
  /// store, because `_done` only survives as long as the screen does and the
  /// run this protects takes hours.
  var _earlier = <String>{};
  String? _busy;
  bool _batch = false;
  bool _stop = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// Mail counts come from the folder cache when it has them. They are only
  /// there to help pick a small folder for the trial run, so a missing cache
  /// costs a label, not the feature — fetching a STATUS for several hundred
  /// folders would cost minutes before anything is shown.
  ///
  /// Stale on purpose: the first run marks the cache out of date, and these
  /// are the numbers from before it. For a folder already done that is visibly
  /// past — its own result line says what happened to it — and for the ones
  /// still queued it is the only figure there is short of asking the server
  /// again. Reading them strictly is what used to blank the whole column.
  Map<String, int> get _counts => {
        for (final f in _storage.loadFolderCache(_app.serverKey,
                allowStale: true) ??
            const <FolderInfo>[])
          f.name: f.count
      };

  Future<void> _load() async {
    setState(() => _loading = true);
    _progress.value = const OpProgress().running('Fetching folder list...');
    try {
      final list = await _imap.resortableFolders(_app.config, _app.password);
      final earlier = _storage.loadResortProgress(_app.serverKey);
      if (!mounted) return;
      setState(() {
        _folders = list;
        _earlier = earlier;
      });
      _progress.value = OpProgress(
          status: 'done',
          message: earlier.isEmpty
              ? '${list.length} folders found.'
              : '${list.length} folders found, ${earlier.length} already '
                  'completed in a previous run.');
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resortOne(String folder) async {
    final n = _counts[folder];
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: const Text('Re-sort this folder?'),
        content: Text(
          'Every mail in "$folder"${n != null ? " ($n)" : ""} will be moved '
          'to its sender\'s folder. Mails with no usable sender domain go to '
          'the inbox. If nothing remains, "$folder" will be deleted.\n\n'
          'Message IDs are backed up first — that is the only record of the '
          'old assignment. Neither the app nor the mail server can undo this.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Re-sort',
                style: TextStyle(color: TF.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = folder);
    try {
      final ids = await _imap.collectMessageIds(
          _app.config, _app.password, folder,
          onProgress: (p) => _progress.value = p);
      final backup =
          await _storage.saveMergeBackup(_app.serverKey, folder, ids);
      debugPrint('[TyrannoFi] Backup: $backup (${ids.length} IDs)');

      final res = await _imap.resortFolder(_app.config, _app.password, folder,
          onProgress: (p) => _progress.value = p);
      if (!mounted) return;
      setState(() => _done[folder] = res);
      _progress.value = OpProgress(
          status: res.complete ? 'done' : 'error',
          message: res.complete
              ? '${_summary(res)}  Backup: $backup'
              : '${res.failed} of ${res.total} mails left behind — '
                  '"$folder" kept.');
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _resortAll() async {
    final pending = (_folders ?? [])
        .where((f) => !_done.containsKey(f) && !_earlier.contains(f))
        .toList();
    if (pending.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: Text('Re-sort ${pending.length} folders?'),
        content: const Text(
          'Every mail will be moved to its sender\'s folder. Empty folders '
          'will be deleted — the existing topic-based structure will be gone '
          'and cannot be restored.\n\n'
          'Mails with no usable sender go to the inbox.\n\n'
          'Each folder\'s assignment is backed up first; if a backup cannot '
          'be written, that folder is skipped.\n\n'
          'The run can be stopped at any time — it pauses at the next folder '
          'boundary, not mid-folder. With many thousands of mails this takes '
          'hours.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Re-sort all',
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
      final results = await _imap.resortAllFolders(
        _app.config,
        _app.password,
        pending,
        shouldStop: () => _stop,
        onSnapshot: (folder, ids) async {
          final path =
              await _storage.saveMergeBackup(_app.serverKey, folder, ids);
          debugPrint('[TyrannoFi] Backup: $path (${ids.length} IDs)');
        },
        onFolder: (done, total, last) {
          if (mounted) setState(() => _done[last.source] = last);
        },
        onProgress: (p) => _progress.value = p,
      );
      final okCount = results.where((r) => r.complete).length;
      final moved = results.fold<int>(0, (s, r) => s + r.moved);
      final inbox = results.fold<int>(0, (s, r) => s + r.toInbox);
      final failed = results.length - okCount;
      _progress.value = OpProgress(
          status: failed == 0 ? 'done' : 'error',
          message: '$okCount of ${pending.length} folders done, '
              '$moved mails re-sorted'
              '${inbox > 0 ? ", $inbox to inbox" : ""}'
              '${failed > 0 ? ", $failed skipped or incomplete" : ""}'
              '${_stop ? " — cancelled" : ""}.');
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _batch = false);
    }
  }

  String _summary(ResortResult r) => [
        if (r.moved > 0) '${r.moved} moved',
        if (r.toInbox > 0) '${r.toInbox} to inbox',
        if (r.stayed > 0) '${r.stayed} already correct',
        if (r.sourceDeleted) 'folder deleted',
      ].join(', ');

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final pending = (folders ?? [])
        .where((f) => !_done.containsKey(f) && !_earlier.contains(f))
        .toList();
    return Scaffold(
      appBar: tfAppBar('RE-SORT BY SENDER'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _warning(),
          ValueListenableBuilder<OpProgress>(
            valueListenable: _progress,
            builder: (_, p, __) => p.status == 'idle'
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ProgressPanel(p)),
          ),
          if (folders == null)
            _loading
                ? const SizedBox.shrink()
                : Center(
                    child: TextButton(
                        onPressed: _load,
                        child: const Text('Retry loading folders')))
          else ...[
            _batchBar(pending),
            const SectionLabel('Folders'),
            for (final f in folders) _folderTile(f),
          ],
        ],
      ),
    );
  }

  Widget _warning() => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: TF.danger.withValues(alpha: 0.12),
          border: Border.all(color: TF.danger, width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.warning_amber_rounded, color: TF.danger),
              SizedBox(width: 8),
              Expanded(
                child: Text('Existing folder structure will be replaced',
                    style: TextStyle(
                        color: TF.danger,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
            ]),
            SizedBox(height: 10),
            Text(
              'Afterwards there will be exactly one folder per sender domain — '
              '"Amazon", not "Shopping/Amazon". Which mail sat in which '
              'category is gone; the server keeps no record of it.\n\n'
              'Each folder\'s message IDs are backed up beforehand. The old '
              'grouping can be looked up, but not restored.\n\n'
              'Run one folder first and check the result. The batch run '
              'will still be available afterwards.',
              style: TextStyle(color: TF.text, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      );

  Widget _batchBar(List<String> pending) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: _batch
            ? Row(
                children: [
                  Expanded(
                    // Folders from an interrupted run count as done, or the
                    // tally would restart at zero halfway through the work.
                    child: Text(
                        '${_done.length + _earlier.length} of '
                        '${_folders!.length} done',
                        style:
                            const TextStyle(color: TF.text2, fontSize: 12)),
                  ),
                  OutlinedButton(
                    onPressed:
                        _stop ? null : () => setState(() => _stop = true),
                    child: Text(_stop ? 'Stopping...' : 'Cancel'),
                  ),
                ],
              )
            // The batch stays locked until one folder has been run and read.
            // A dead button with no reason given reads as a broken app, so the
            // reason takes the button's place rather than sitting beside it.
            //
            // An interrupted run counts as that trial: those folders went
            // through and their results were seen. Demanding another single
            // run before resuming would be asking twice for the same proof.
            : (_done.isEmpty && _earlier.isEmpty)
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.lock_outline, size: 15, color: TF.text2),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'The batch run unlocks once one folder has been '
                          'run individually. Pick a small one — you\'ll know '
                          'in a minute whether the result is what you want.',
                          style: const TextStyle(
                                  color: TF.text2, fontSize: 12)
                              .copyWith(height: 1.4),
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.playlist_add_check, size: 18),
                      label: Text('Re-sort all ${pending.length}'),
                      onPressed: (_busy != null || pending.isEmpty)
                          ? null
                          : _resortAll,
                    ),
                  ),
      );

  Widget _folderTile(String f) {
    final res = _done[f];
    final busy = _busy == f;
    final n = _counts[f];
    // Done in a run that ended before this screen was opened. There is no
    // result to show — only the fact, which is what keeps the folder from
    // being offered again.
    final earlier = res == null && _earlier.contains(f);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TF.surface,
        border: Border.all(
            color: res == null
                ? (earlier ? TF.ok : TF.border)
                : res.complete
                    ? TF.ok
                    : TF.danger),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$f${n != null ? "  ($n)" : ""}',
                    style: const TextStyle(color: TF.text)),
                if (res != null)
                  Text(
                    res.error ??
                        (res.complete
                            ? _summary(res)
                            : '${res.failed} of ${res.total} left behind'),
                    style: TextStyle(
                        color: res.complete ? TF.ok : TF.danger, fontSize: 12),
                  )
                else if (earlier)
                  const Text('completed in a previous run',
                      style: TextStyle(color: TF.ok, fontSize: 12)),
              ],
            ),
          ),
          if (res == null && !earlier)
            busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : OutlinedButton(
                    onPressed: (_busy != null || _batch)
                        ? null
                        : () => _resortOne(f),
                    child: const Text('Trial run'),
                  ),
        ],
      ),
    );
  }
}
