import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../utils/folder_merge.dart';
import '../widgets/common.dart';
import 'inbox_screen.dart';
import 'merge_screen.dart';

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});
  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _storage = StorageService.instance;
  final _ruleProgress = ValueNotifier<OpProgress>(const OpProgress.idle());
  List<FolderInfo>? _folders;
  String? _error;
  bool _loading = false;
  bool _findingRules = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ruleProgress.dispose();
    super.dispose();
  }

  /// Rule discovery: reads only the newest few hundred mails per folder and
  /// turns the dominant sender domains into rules. Cheap by design — the full
  /// per-folder analysis lives in [FolderDetailScreen].
  Future<void> _findRules() async {
    if (_findingRules) return;
    if (!_app.hasCredentials) {
      showSnack(context, 'Please set up account + password first.',
          error: true);
      return;
    }
    setState(() => _findingRules = true);
    try {
      final folderDomains = await _imap.scanFoldersForRuleImport(
          _app.config, _app.password,
          onProgress: (p) => _ruleProgress.value = p);
      final added = await _storage.importRulesFromFolders(
          _app.serverKey, folderDomains,
          sampleSize: ImapService.defaultRuleSampleSize);
      if (mounted) {
        showSnack(
            context,
            added > 0
                ? '$added rule(s) imported from folders.'
                : 'No new rules found — everything already covered.');
      }
    } catch (e) {
      _ruleProgress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _findingRules = false);
    }
  }

  List<RuleRepair> _repairs() => _folders == null
      ? const []
      : planRuleRepairs(_storage.allRules(_app.serverKey),
          _folders!.map((f) => f.name).toList());

  /// Offer to repoint rules left pointing at folders a merge deleted. Shown
  /// only when there are any: with a healthy config the bar stays as it was.
  Future<void> _repairRules() async {
    final repairs = _repairs();
    if (repairs.isEmpty) return;
    final sample = repairs
        .take(5)
        .map((r) => '${r.rule.moveTo} → ${r.newTarget}')
        .join('\n');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TF.surface,
        title: Text('Redirect ${counted(repairs.length, 'rule', 'rules')}?'),
        content: Text(
          'These rules point to folders that no longer exist — sorting '
          'would recreate them and undo the merge.\n\n$sample'
          '${repairs.length > 5 ? '\n… and ${repairs.length - 5} more' : ''}'
          '\n\nOnly rules are changed, no emails are moved.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Redirect')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final changed = await _storage.applyRuleRepairs(_app.serverKey, repairs);
    if (mounted) {
      setState(() {});
      showSnack(context, '${counted(changed, 'rule', 'rules')} redirected.');
    }
  }

  String _mergeLabel() {
    if (_folders == null) return 'Duplicates';
    final n = planFolderMerges(_folders!).pairs.length;
    return n == 0 ? 'No duplicates' : 'Duplicates ($n)';
  }

  Future<void> _openMerge() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => MergeScreen(folders: _folders!)));
    if (mounted) _load(force: true);
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final f = await _imap.listFolders(_app.config, _app.password,
          forceRefresh: force);
      setState(() => _folders = f);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: tfAppBar(
        'FOLDERS',
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(force: true),
          ),
        ],
      ),
      body: Column(
        children: [
          _actionBar(),
          Expanded(
            child: _loading && _folders == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? EmptyState(icon: Icons.error_outline, message: _error!)
                    : (_folders == null || _folders!.isEmpty)
                        ? const EmptyState(
                            icon: Icons.folder_off,
                            message: 'No folders found.')
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                            itemCount: _folders!.length,
                            itemBuilder: (_, i) => _folderTile(_folders![i]),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar() {
    final busy = _loading || _findingRules;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Scan folders'),
                  onPressed: busy ? null : () => _load(force: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Find rules'),
                  onPressed: busy ? null : _findRules,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.merge_type, size: 18),
                label: Text(_mergeLabel()),
                onPressed: (busy || _folders == null) ? null : _openMerge,
              ),
            ),
          ),
          if (_repairs().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.healing, size: 18),
                  label: Text(
                      'Repair ${counted(_repairs().length, 'rule', 'rules')}'),
                  style: OutlinedButton.styleFrom(foregroundColor: TF.danger),
                  onPressed: busy ? null : _repairRules,
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Find rules only checks the newest email per folder.',
              style: TextStyle(color: TF.text2, fontSize: 11),
            ),
          ),
          ValueListenableBuilder<OpProgress>(
            valueListenable: _ruleProgress,
            builder: (_, p, __) => p.status == 'idle'
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: ProgressPanel(p),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _folderTile(FolderInfo f) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder, color: TF.accent),
        title: Text(f.name, style: const TextStyle(fontSize: 14)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${f.count}',
                style: const TextStyle(color: TF.text2, fontSize: 12)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: TF.text2),
          ],
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => FolderDetailScreen(folder: f.name)),
        ),
      ),
    );
  }
}

class FolderDetailScreen extends StatefulWidget {
  final String folder;
  const FolderDetailScreen({super.key, required this.folder});
  @override
  State<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

class _FolderDetailScreenState extends State<FolderDetailScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _progress = ValueNotifier<OpProgress>(const OpProgress.idle());
  FolderScanResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() => _run(() async {
        final r = await _imap.scanFolder(_app.config, _app.password, widget.folder,
            onProgress: (p) => _progress.value = p);
        setState(() => _result = r);
      });

  Future<void> _sortAll() => _run(() async {
        await _imap.sortFolderAll(_app.config, _app.password, widget.folder,
            onProgress: (p) => _progress.value = p);
      });

  Future<void> _fix() => _run(() async {
        await _imap.fixFolder(_app.config, _app.password, widget.folder,
            onProgress: (p) => _progress.value = p);
      });

  Future<void> _deleteDomain(FolderDomainEntry d) async {
    final ok = await _confirm('Delete ${d.domain}?',
        '${d.count} email(s) from ${d.domain} will be deleted from "${widget.folder}".');
    if (ok != true) return;
    _run(() async {
      final n = await _imap.deleteDomainFromFolder(
          _app.config, _app.password, widget.folder, d.domain);
      if (mounted) showSnack(context, '$n email(s) deleted.');
      await _scan();
    });
  }

  Future<void> _moveDomain(FolderDomainEntry d) async {
    final targetCtl = TextEditingController(text: d.shouldBe == '?' ? '' : d.shouldBe);
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${d.domain}'),
        content: TextField(
          controller: targetCtl,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Target folder'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, targetCtl.text.trim()),
              child: const Text('Move')),
        ],
      ),
    );
    if (target == null || target.isEmpty) return;
    _run(() async {
      final n = await _imap.moveDomainToFolder(
          _app.config, _app.password, widget.folder, d.domain, target);
      if (mounted) showSnack(context, '$n email(s) moved to "$target".');
      await _scan();
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
                child: const Text('OK')),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: tfAppBar(
        widget.folder.toUpperCase(),
        actions: [
          IconButton(
            icon: const Icon(Icons.mail_outline),
            tooltip: 'Read emails',
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => InboxScreen(folder: widget.folder))),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('Scan'),
                        onPressed: _busy ? null : _scan,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.sort, size: 18),
                        label: const Text('Sort'),
                        onPressed: _busy ? null : _sortAll,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.healing, size: 18),
                        label: const Text('Fix'),
                        onPressed: _busy ? null : _fix,
                      ),
                    ),
                  ],
                ),
                ValueListenableBuilder<OpProgress>(
                  valueListenable: _progress,
                  builder: (_, p, __) => Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ProgressPanel(p),
                  ),
                ),
              ],
            ),
          ),
          if (r != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    '${r.domains.length} domains · ${r.wrong} misplaced',
                    style: const TextStyle(color: TF.accent2, fontSize: 12)),
              ),
            ),
          Expanded(
            child: r == null
                ? const EmptyState(
                    icon: Icons.folder_open,
                    message: 'Tap “Scan” to analyze the folder.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: r.domains.length,
                    itemBuilder: (_, i) => _domainTile(r.domains[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _domainTile(FolderDomainEntry d) {
    final wrong = d.wrongCount > 0;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: TF.surface2,
          child: Text('${d.count}',
              style: TextStyle(
                  color: wrong ? TF.danger : TF.accent, fontSize: 12)),
        ),
        title: Text(d.domain, style: const TextStyle(fontSize: 14)),
        subtitle: wrong
            ? Text('${d.wrongCount}× misplaced → should be: ${d.shouldBe}',
                style: const TextStyle(color: TF.danger, fontSize: 11))
            : (d.examples.isEmpty
                ? null
                : Text(d.examples.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TF.text2, fontSize: 11))),
        trailing: PopupMenuButton<String>(
          color: TF.surface,
          icon: const Icon(Icons.more_vert, color: TF.text2),
          onSelected: (v) {
            if (v == 'delete') _deleteDomain(d);
            if (v == 'move') _moveDomain(d);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'move', child: Text('Move to folder')),
            PopupMenuItem(value: 'delete', child: Text('Delete from folder')),
          ],
        ),
      ),
    );
  }
}
