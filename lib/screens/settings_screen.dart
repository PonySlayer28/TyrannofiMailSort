import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/mail_server.dart';
import '../services/imap_service.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'backups_screen.dart';
import 'danger_screen.dart';
import 'resort_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = StorageService.instance;
  final _app = AppState.instance;

  late String _serverKey;
  final _emailCtl = TextEditingController();
  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController();
  final _passCtl = TextEditingController();
  bool _obscure = true;
  bool _testing = false;
  bool _sortBySender = false;

  @override
  void initState() {
    super.initState();
    _serverKey = _app.serverKey;
    _loadServer(_serverKey);
  }

  void _loadServer(String key) {
    final cfg = _storage.loadConfig(key);
    _serverKey = key;
    _emailCtl.text = cfg.email;
    _hostCtl.text = cfg.imapServer;
    _portCtl.text = cfg.imapPort.toString();
    _sortBySender = cfg.sortBySender;
    _storage.loadPassword(key, cfg.email).then((pw) {
      if (mounted) setState(() => _passCtl.text = pw);
    });
    setState(() {});
  }

  @override
  void dispose() {
    _emailCtl.dispose();
    _hostCtl.dispose();
    _portCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: tfAppBar('SETTINGS'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          const SectionLabel('Provider'),
          DropdownButtonFormField<String>(
            initialValue: _serverKey,
            decoration: const InputDecoration(labelText: 'Mail provider'),
            dropdownColor: TF.surface,
            items: kServers.values
                .map((s) => DropdownMenuItem(value: s.key, child: Text(s.label)))
                .toList(),
            onChanged: (key) {
              if (key != null) _loadServer(key);
            },
          ),
          const SectionLabel('Credentials'),
          TextField(
            controller: _emailCtl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email address'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passCtl,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Password / App password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off,
                    color: TF.text2),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SectionLabel('IMAP-Server'),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostCtl,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Host'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _portCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Save'),
            onPressed: _save,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering),
            label: const Text('Test connection'),
            onPressed: _testing ? null : _test,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, color: TF.danger),
            label: const Text('Delete password',
                style: TextStyle(color: TF.danger)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TF.danger)),
            onPressed: _deletePassword,
          ),
          const SizedBox(height: 24),
          const Text(
            'Note: Gmail/Yahoo require an app password '
            '(Two-factor authentication → App passwords).',
            style: TextStyle(color: TF.text2, fontSize: 11),
          ),
          const SizedBox(height: 32),
          const SectionLabel('Backups'),
          const Text(
            'Before every merge and bulk action, the assignment of emails to '
            'folders is recorded. View and share them here.',
            style: TextStyle(color: TF.text2, fontSize: 11),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: const Text('View backups'),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BackupsScreen())),
          ),
          const SizedBox(height: 32),
          const SectionLabel('Sorting'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _sortBySender,
            onChanged: _setSortBySender,
            title: const Text('Sort by sender',
                style: TextStyle(color: TF.text, fontSize: 14)),
            subtitle: const Text(
              'The sender determines the folder, the rule list is not read. '
              'An unknown sender gets its own folder instead of staying '
              'in the inbox.',
              style: TextStyle(color: TF.text2, fontSize: 11),
            ),
          ),
          const SizedBox(height: 32),
          const SectionLabel('Re-sort'),
          const Text(
            'Rebuild the entire folder tree by sender: one folder per sender '
            'domain, the existing topic-based structure is replaced.',
            style: TextStyle(color: TF.text2, fontSize: 11),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.alt_route, color: TF.danger),
            label: const Text('Re-sort by sender',
                style: TextStyle(color: TF.danger)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TF.danger)),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ResortScreen())),
          ),
          const SizedBox(height: 32),
          const SectionLabel('Last resort'),
          const Text(
            'Only when the folder structure is beyond repair: move aside or '
            'delete all folders at once.',
            style: TextStyle(color: TF.text2, fontSize: 11),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.warning_amber_rounded, color: TF.danger),
            label: const Text('Folder emergency tools',
                style: TextStyle(color: TF.danger)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TF.danger)),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DangerScreen())),
          ),
        ],
      ),
    );
  }

  Future<void> _persist() async {
    final cfg = _storage.loadConfig(_serverKey);
    cfg.email = _emailCtl.text.trim();
    cfg.imapServer = _hostCtl.text.trim();
    cfg.imapPort = int.tryParse(_portCtl.text.trim()) ?? cfg.imapPort;
    cfg.sortBySender = _sortBySender;
    await _storage.saveConfig(cfg);
    if (_passCtl.text.isNotEmpty && cfg.email.isNotEmpty) {
      await _storage.savePassword(_serverKey, cfg.email, _passCtl.text);
    }
    await _app.selectServer(_serverKey);
  }

  Future<void> _save() async {
    await _persist();
    if (mounted) showSnack(context, 'Saved!');
  }

  /// Takes effect immediately rather than on the next "Save": a switch
  /// that silently waits for a save button elsewhere on the screen reads as
  /// already applied.
  Future<void> _setSortBySender(bool on) async {
    setState(() => _sortBySender = on);
    await _persist();
    if (mounted) {
      showSnack(
          context,
          on
              ? 'Now sorting by sender.'
              : 'Now sorting by rule list.');
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    await _persist();
    try {
      await ImapService.instance
          .testConnection(_storage.loadConfig(_serverKey), _passCtl.text);
      if (mounted) showSnack(context, 'Connection successful!');
    } catch (e) {
      if (mounted) showSnack(context, 'Failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _deletePassword() async {
    await _storage.deletePassword(_serverKey, _emailCtl.text.trim());
    setState(() => _passCtl.text = '');
    await _app.selectServer(_serverKey);
    if (mounted) showSnack(context, 'Password deleted.');
  }
}
