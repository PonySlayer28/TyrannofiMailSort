import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/spam_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SpamScreen extends StatefulWidget {
  const SpamScreen({super.key});
  @override
  State<SpamScreen> createState() => _SpamScreenState();
}

class _SpamScreenState extends State<SpamScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  final _storage = StorageService.instance;
  final _progress = ValueNotifier<OpProgress>(const OpProgress.idle());

  String _mode = 'smart';
  bool _busy = false;
  List<SpamEntry> _results = [];

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _imap.spamScan(_app.config, _app.password, _mode,
          cachedScan: _app.scan, onProgress: (p) => _progress.value = p);
      setState(() => _results = r);
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _blacklist(SpamEntry e) async {
    final err = await _storage.blacklistAdd(e.domain, note: 'from spam scan');
    if (mounted) {
      showSnack(context, err ?? '${e.domain} added to blacklist.',
          error: err != null);
    }
  }

  Color _scoreColor(int s) {
    if (s >= 70) return TF.danger;
    if (s >= 40) return Colors.orange;
    return TF.text2;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: tfAppBar(
        'SPAM SCANNER',
        actions: [
          IconButton(
            icon: const Icon(Icons.block),
            tooltip: 'Blacklist',
            onPressed: _openBlacklist,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SegmentedButton<String>(
                  style: SegmentedButton.styleFrom(
                    backgroundColor: TF.surface,
                    selectedBackgroundColor: TF.accent.withValues(alpha: 0.18),
                    foregroundColor: TF.text2,
                    selectedForegroundColor: TF.accent,
                    side: const BorderSide(color: TF.border),
                  ),
                  segments: const [
                    ButtonSegment(value: 'smart', label: Text('Smart')),
                    ButtonSegment(value: 'inbox', label: Text('INBOX')),
                    ButtonSegment(value: 'full', label: Text('All')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  icon: const Icon(Icons.shield_moon),
                  label: Text(_busy ? 'Scanning...' : 'Start spam scan'),
                  onPressed: _busy ? null : _scan,
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
          Expanded(
            child: _results.isEmpty
                ? const EmptyState(
                    icon: Icons.shield,
                    message: 'No scan yet.\nSmart uses the latest '
                        'scan data.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: _results.length,
                    itemBuilder: (_, i) => _spamTile(_results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _spamTile(SpamEntry e) {
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: _scoreColor(e.score).withValues(alpha: 0.16),
          child: Text('${e.score}',
              style: TextStyle(
                  color: _scoreColor(e.score),
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ),
        title: Text(e.domain, style: const TextStyle(fontSize: 14)),
        subtitle: Text('${e.count} emails',
            style: const TextStyle(color: TF.text2, fontSize: 11)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (e.exampleSubject.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('„${e.exampleSubject}"',
                  style: const TextStyle(color: TF.text2, fontSize: 12)),
            ),
          const SizedBox(height: 6),
          ...e.reasons.map((r) => Align(
                alignment: Alignment.centerLeft,
                child: Text('• $r',
                    style: const TextStyle(color: TF.accent2, fontSize: 12)),
              )),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.block, size: 16, color: TF.danger),
              label: const Text('Blacklist',
                  style: TextStyle(color: TF.danger, fontSize: 12)),
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: TF.danger)),
              onPressed: () => _blacklist(e),
            ),
          ),
        ],
      ),
    );
  }

  void _openBlacklist() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const BlacklistScreen()));
  }
}

class BlacklistScreen extends StatefulWidget {
  const BlacklistScreen({super.key});
  @override
  State<BlacklistScreen> createState() => _BlacklistScreenState();
}

class _BlacklistScreenState extends State<BlacklistScreen> {
  final _storage = StorageService.instance;
  final _spam = SpamService.instance;

  @override
  Widget build(BuildContext context) {
    final entries = _storage.loadBlacklist().entries.toList();
    return Scaffold(
      appBar: tfAppBar(
        'BLACKLIST',
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: _add),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_download, color: TF.accent),
                title: const Text('Disposable domains',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                    _spam.isLoaded
                        ? '${_spam.dbCount} domains loaded'
                        : 'Not loaded',
                    style: const TextStyle(color: TF.text2, fontSize: 11)),
                trailing: TextButton(
                  onPressed: () async {
                    await _spam.loadDisposable(force: true);
                    if (mounted) setState(() {});
                  },
                  child: const Text('Update'),
                ),
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? const EmptyState(
                    icon: Icons.block, message: 'No entries.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.block, color: TF.danger),
                          title:
                              Text(e.key, style: const TextStyle(fontSize: 13)),
                          subtitle: Text('${e.value['type'] ?? ''}',
                              style: const TextStyle(
                                  color: TF.text2, fontSize: 11)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: TF.text2),
                            onPressed: () async {
                              await _storage.blacklistRemove(e.key);
                              setState(() {});
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final ctl = TextEditingController();
    final entry = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add to blacklist'),
        content: TextField(
          controller: ctl,
          autocorrect: false,
          decoration: const InputDecoration(
              labelText: 'Domain or email', hintText: 'e.g. spam.com'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (entry != null && entry.isNotEmpty) {
      final err = await _storage.blacklistAdd(entry);
      if (mounted) {
        if (err != null) showSnack(context, err, error: true);
        setState(() {});
      }
    }
  }
}
