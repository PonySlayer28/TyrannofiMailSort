import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/mail_server.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'folders_screen.dart';
import 'inbox_screen.dart';
import 'maintenance_screen.dart';
import 'rules_screen.dart';
import 'scan_screen.dart';
import 'settings_screen.dart';
import 'spam_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _app = AppState.instance;

  @override
  void initState() {
    super.initState();
    _app.selectServer(_app.serverKey);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _app,
      builder: (context, _) {
        final cfg = _app.config;
        return Scaffold(
          appBar: tfAppBar(
            'TYRANNOFI',
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _open(const SettingsScreen()),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const Text('MAIL ORGANIZER',
                  style: TextStyle(
                      color: TF.text2, fontSize: 10, letterSpacing: 4)),
              const SectionLabel('Account'),
              _serverSelector(cfg.serverKey),
              const SizedBox(height: 10),
              _credentialStatus(cfg.email),
              const SectionLabel('Tools'),
              ActionCard(
                icon: Icons.radar,
                title: 'Inbox Scan',
                subtitle: 'Group emails by domain',
                onTap: () => _open(const ScanScreen()),
              ),
              ActionCard(
                icon: Icons.rule,
                title: 'Rules',
                subtitle: '${cfg.allRules.length} rules '
                    '(${cfg.activeRules.length} active)',
                onTap: () => _open(const RulesScreen()),
              ),
              ActionCard(
                icon: Icons.sort,
                title: 'Sort & Clean Up',
                subtitle: 'Apply rules, delete duplicates',
                onTap: () => _requireCreds(const MaintenanceScreen()),
              ),
              ActionCard(
                icon: Icons.folder_open,
                title: 'Folders',
                subtitle: 'Browse, scan, fix',
                onTap: () => _requireCreds(const FoldersScreen()),
              ),
              ActionCard(
                icon: Icons.shield,
                title: 'Spam Scanner',
                subtitle: 'Find suspicious senders',
                color: TF.danger,
                onTap: () => _requireCreds(const SpamScreen()),
              ),
              ActionCard(
                icon: Icons.mail_outline,
                title: 'Mailbox',
                subtitle: 'Read emails, mark as read',
                onTap: () => _requireCreds(const InboxScreen()),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _serverSelector(String current) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: TF.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TF.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          isExpanded: true,
          dropdownColor: TF.surface,
          icon: const Icon(Icons.expand_more, color: TF.text2),
          items: kServers.values
              .map((s) => DropdownMenuItem(
                    value: s.key,
                    child: Row(
                      children: [
                        const Icon(Icons.dns, size: 18, color: TF.accent),
                        const SizedBox(width: 10),
                        Text(s.label,
                            style: const TextStyle(
                                color: TF.text, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ))
              .toList(),
          onChanged: (key) {
            if (key != null) _app.selectServer(key);
          },
        ),
      ),
    );
  }

  Widget _credentialStatus(String email) {
    final ok = _app.hasCredentials;
    return Card(
      child: ListTile(
        leading: Icon(ok ? Icons.verified_user : Icons.lock_outline,
            color: ok ? TF.ok : TF.text2),
        title: Text(email.isEmpty ? 'No account configured' : email,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text(ok ? 'Password saved' : 'Tap to set up',
            style: const TextStyle(color: TF.text2, fontSize: 11)),
        trailing: const Icon(Icons.chevron_right, color: TF.text2),
        onTap: () => _open(const SettingsScreen()),
      ),
    );
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _app.reload();
  }

  void _requireCreds(Widget screen) {
    if (!_app.hasCredentials) {
      showSnack(context, 'Please set up account + password first.',
          error: true);
      _open(const SettingsScreen());
      return;
    }
    _open(screen);
  }
}
