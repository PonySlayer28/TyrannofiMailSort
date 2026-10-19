import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../utils/domain_utils.dart';
import '../widgets/common.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _app = AppState.instance;
  final _storage = StorageService.instance;
  final _progress = ValueNotifier<OpProgress>(const OpProgress.idle());
  bool _busy = false;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    if (!_app.hasCredentials) {
      showSnack(context, 'Please set up an account first.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await ImapService.instance.scanInbox(
        _app.config,
        _app.password,
        onProgress: (p) => _progress.value = p,
      );
      _app.setScan(result);
    } catch (e) {
      _progress.value = OpProgress(status: 'error', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _autoAssign() async {
    final scan = _app.scan;
    if (scan == null) return;
    final added = await _storage.autoAssign(_app.serverKey, scan);
    await _app.reload();
    if (mounted) {
      showSnack(context, '$added rules created.');
      setState(() {});
    }
  }

  Future<void> _quickRule(DomainScanEntry d) async {
    final pattern = d.domain.contains('.') ? d.domain.split('.').first : d.domain;
    final err = await _storage.addRule(
        _app.serverKey, '', pattern, domainToFolder(d.domain));
    await _app.reload();
    if (mounted) {
      showSnack(context, err ?? 'Rule for ${d.domain} created.',
          error: err != null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = _app.scan;
    return Scaffold(
      appBar: tfAppBar(
        'INBOX SCAN',
        actions: [
          if (scan != null && scan.domains.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Auto'),
              onPressed: _busy ? null : _autoAssign,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.radar),
                  label: Text(_busy ? 'Scanning...' : 'Scan INBOX'),
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
          if (scan != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${scan.domains.length} domains',
                      style: const TextStyle(
                          color: TF.accent2, fontWeight: FontWeight.w600)),
                  Text('${scan.analyzed} emails',
                      style: const TextStyle(color: TF.text2, fontSize: 12)),
                ],
              ),
            ),
          Expanded(
            child: scan == null || scan.domains.isEmpty
                ? const EmptyState(
                    icon: Icons.radar,
                    message: 'No scan yet.\nTap “Scan INBOX”.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: scan.domains.length,
                    itemBuilder: (_, i) => _domainTile(scan.domains[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _domainTile(DomainScanEntry d) {
    return Card(
      child: ListTile(
        title: Text(d.domain,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: d.examples.isEmpty
            ? null
            : Text(d.examples.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: TF.text2, fontSize: 11)),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: TF.surface2,
          child: Text('${d.count}',
              style: const TextStyle(color: TF.accent, fontSize: 12)),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.add_circle_outline, color: TF.accent),
          tooltip: 'Create rule',
          onPressed: () => _quickRule(d),
        ),
      ),
    );
  }
}
