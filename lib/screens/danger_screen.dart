import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The last resort: push the whole folder tree aside, or delete it.
///
/// Only for a mailbox whose structure is beyond repair. Both operations touch
/// every folder at once, and neither has an undo on the server side — so the
/// warning is part of the screen rather than a dialog that can be dismissed
/// before it is read, and deleting additionally requires the word to be typed.
class DangerScreen extends StatefulWidget {
  const DangerScreen({super.key});

  @override
  State<DangerScreen> createState() => _DangerScreenState();
}

class _DangerScreenState extends State<DangerScreen> {
  static const _confirmWord = 'DELETE';

  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _storage = StorageService.instance;
  final _progress = ValueNotifier<OpProgress>(const OpProgress.idle());
  final _parentCtrl = TextEditingController(text: 'Old');
  final _confirmCtrl = TextEditingController();
  bool _busy = false;

  /// Set by the cancel button; the reset run reads it between two folders, so a
  /// cancel never tears one in half.
  bool _stop = false;

  @override
  void dispose() {
    _progress.dispose();
    _parentCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  /// Both operations record the tree first — it is the only thing that says
  /// what was there a minute ago.
  Future<String?> _snapshot() async {
    final folders = await _imap.snapshotFolderList(_app.config, _app.password,
        onProgress: (p) => _progress.value = p);
    if (folders.isEmpty) return null;
    return _storage.saveFolderSnapshot(_app.serverKey, folders);
  }

  Future<void> _run(Future<int> Function() op, String verb) async {
    setState(() => _busy = true);
    try {
      final backup = await _snapshot();
      final n = await op();
      _progress.value = OpProgress(
          status: 'done',
          message: '$n folders $verb.'
              '${backup != null ? " List saved: $backup" : ""}');
      _confirmCtrl.clear();
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Empty every folder into the INBOX and drop what is left.
  ///
  /// The undo for a sort gone wrong, and the only bulk operation here whose
  /// effect can be taken back: no mail is deleted, and sorting again from the
  /// inbox reproduces the tree. Held apart from the two operations below
  /// because those cannot be undone at all.
  Future<void> _resetToInbox() async {
    setState(() => _busy = true);
    _stop = false;
    try {
      final folders = await _imap.resortableFolders(_app.config, _app.password);
      if (folders.isEmpty) {
        _progress.value = const OpProgress(
            status: 'done', message: 'No folders to reset.');
        return;
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: TF.surface,
          title: Text('Empty ${folders.length} folders?'),
          content: Text(
            'All emails from ${folders.length} folders will be moved to the '
            'inbox, then the empty folders will be deleted.\n\n'
            'No email is deleted — they only lose their sorting. Since sorting '
            'is based solely on the sender, running the sort again restores '
            'the same state.\n\n'
            'Inbox, Drafts, Sent and Trash remain untouched.\n\n'
            'Each folder is backed up before processing. The run can be '
            'cancelled at any time and stops at the next folder boundary. '
            'With many thousands of emails this takes hours.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Move all to inbox',
                  style: TextStyle(color: TF.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;

      final results = await _imap.resetAllToInbox(
        _app.config,
        _app.password,
        folders,
        shouldStop: () => _stop,
        onSnapshot: (folder, ids) async {
          final path =
              await _storage.saveMergeBackup(_app.serverKey, folder, ids);
          debugPrint('[TyrannoFi] Backup: $path (${ids.length} IDs)');
        },
        onProgress: (p) => _progress.value = p,
      );
      final moved = results.fold<int>(0, (s, r) => s + r.moved);
      final deleted = results.where((r) => r.sourceDeleted).length;
      final failed = results.where((r) => !r.complete).length;
      _progress.value = OpProgress(
          status: failed == 0 ? 'done' : 'error',
          message: '${counted(moved, 'email', 'emails')} moved to inbox, '
              '${counted(deleted, 'folder', 'folders')} deleted'
              '${failed > 0 ? ", $failed incomplete" : ""}'
              '${_stop ? " — cancelled" : ""}.');
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmThen(String title, String body, VoidCallback go) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue',
                  style: TextStyle(color: TF.danger))),
        ],
      ),
    );
    if (ok == true) go();
  }

  @override
  Widget build(BuildContext context) {
    final armed = _confirmCtrl.text.trim().toUpperCase() == _confirmWord;
    return Scaffold(
      appBar: tfAppBar('LAST RESORT'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
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
          _resetCard(),
          const SizedBox(height: 12),
          _renameCard(),
          const SizedBox(height: 12),
          _deleteCard(armed),
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
                child: Text('This page modifies ALL folders at once',
                    style: TextStyle(
                        color: TF.danger,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
            ]),
            SizedBox(height: 10),
            Text(
              'There is no undo. The server keeps no record of which folder '
              'an email belonged to — once the structure is gone, it cannot '
              'be reconstructed.\n\n'
              'On Gmail, folders are labels: deleting removes the assignment, '
              'the emails themselves remain accessible under "All Mail". '
              'On other IMAP servers, emails disappear with the folder.\n\n'
              'Both actions save the folder list with email counts beforehand. '
              'This preserves the structure, not the assignment of individual '
              'emails.',
              style: TextStyle(color: TF.text, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      );

  /// Deliberately the first card and the only one not framed in red: it is the
  /// way back, not a way out. Someone who arrives here in a panic should meet
  /// the reversible option before the two that are not.
  Widget _resetCard() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TF.surface,
          border: Border.all(color: TF.ok),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.undo, color: TF.ok, size: 18),
              SizedBox(width: 8),
              Text('Move everything back to inbox',
                  style:
                      TextStyle(color: TF.ok, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            const Text(
              'The way back when a sort went wrong: every email moves from '
              'its folder back to the inbox, then the empty folders are '
              'deleted.\n\n'
              'No email is lost — they only lose their sorting. Since sorting '
              'is based solely on the sender, running it again produces the '
              'same result. This is the only bulk action here that can be '
              'undone.\n\n'
              'Inbox, Drafts, Sent and Trash are left alone.',
              style: TextStyle(color: TF.text2, fontSize: 12),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: _busy
                  ? OutlinedButton(
                      onPressed:
                          _stop ? null : () => setState(() => _stop = true),
                      child: Text(_stop ? 'Stopping...' : 'Cancel'),
                    )
                  : ElevatedButton.icon(
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Move all to inbox'),
                      onPressed: _resetToInbox,
                    ),
            ),
          ],
        ),
      );

  Widget _renameCard() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TF.surface,
          border: Border.all(color: TF.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Push all folders aside',
                style:
                    TextStyle(color: TF.cream, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              'Every folder moves under a common parent folder: "Amazon" '
              'becomes "Old/Amazon". No email is moved, nothing is deleted — '
              'the old structure remains fully readable and can be renamed '
              'back. The recommended approach.',
              style: TextStyle(color: TF.text2, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _parentCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Parent folder'),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _doRename,
                child: const Text('Push aside'),
              ),
            ),
          ],
        ),
      );

  void _doRename() {
    final parent = _parentCtrl.text.trim();
    if (parent.isEmpty || parent.contains('/')) {
      showSnack(context, 'Parent folder must not be empty or contain /.',
          error: true);
      return;
    }
    _confirmThen(
      'Push all folders aside?',
      'Every folder will be moved under "$parent". Emails remain '
          'untouched, the structure is preserved.',
      () => _run(
          () => _imap.renameAllFolders(_app.config, _app.password, parent,
              onProgress: (p) => _progress.value = p),
          'moved'),
    );
  }

  Widget _deleteCard(bool armed) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TF.surface,
          border: Border.all(color: TF.danger),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Delete all folders',
                style:
                    TextStyle(color: TF.danger, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              'Removes every folder. The assignment of which email belonged '
              'where is permanently lost afterwards.',
              style: TextStyle(color: TF.text2, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmCtrl,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Type $_confirmWord to unlock',
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: armed ? TF.danger : TF.surface2),
                onPressed: (_busy || !armed) ? null : _doDelete,
                child: const Text('Delete all folders'),
              ),
            ),
          ],
        ),
      );

  void _doDelete() => _confirmThen(
        'Really delete all folders?',
        'Last warning. Every folder will be removed. On Gmail, emails remain '
            'under "All Mail", but their sorting is gone and cannot be '
            'restored.',
        () => _run(
            () => _imap.deleteAllFolders(_app.config, _app.password,
                onProgress: (p) => _progress.value = p),
            'deleted'),
      );
}
