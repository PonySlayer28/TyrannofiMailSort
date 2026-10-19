import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/results.dart';
import '../services/storage_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The written record of what the destructive operations moved.
///
/// Every merge writes the Message-IDs of the folder it empties, because the
/// server keeps no history of which folder a mail came from — without these
/// files the old grouping is gone for good. They were being written from the
/// start, but only reachable with a cable and a shell, which made the promise
/// in the merge dialog true and useless at the same time. Here they can be
/// read and handed out.
class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key});
  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  final _storage = StorageService.instance;
  List<BackupFile>? _files;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await _storage.listBackups();
    if (mounted) setState(() => _files = f);
  }

  Future<void> _shareAll() async {
    final files = _files ?? [];
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(
      files: files.map((f) => XFile(f.path)).toList(),
      subject: 'TyrannoFi — Backups',
    ));
  }

  Future<void> _shareOne(BackupFile f) => SharePlus.instance
      .share(ShareParams(files: [XFile(f.path)], subject: f.folder));

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final mails = files?.fold<int>(0, (s, f) => s + f.count) ?? 0;
    return Scaffold(
      appBar: tfAppBar('BACKUPS'),
      body: files == null
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
              ? const EmptyState(
                  icon: Icons.inventory_2_outlined,
                  message: 'Nothing backed up yet.\nBackups are created '
                      'before folders are merged or deleted.')
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '${files.length} files, $mails identifiers. Each lists '
                        'the source folder, timestamp and Message-IDs it '
                        'contained — use them to find the old grouping via '
                        'search. The emails themselves are not included.',
                        style: const TextStyle(color: TF.text2, fontSize: 12),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: Text(files.length == 1
                            ? 'Share backup'
                            : 'Share all ${files.length}'),
                        onPressed: _shareAll,
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final f in files) _tile(f),
                  ],
                ),
    );
  }

  Widget _tile(BackupFile f) => Card(
        child: ListTile(
          leading: const Icon(Icons.description_outlined, color: TF.accent),
          title: Text(f.folder.isEmpty ? _basename(f.path) : f.folder,
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            [
              if (f.count > 0) counted(f.count, 'email', 'emails'),
              if (f.savedAt != null) _when(f.savedAt!),
            ].join('  ·  '),
            style: const TextStyle(color: TF.text2, fontSize: 11),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.ios_share, size: 18, color: TF.text2),
            onPressed: () => _shareOne(f),
          ),
        ),
      );

  String _basename(String p) => p.split(Platform.pathSeparator).last;

  String _when(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}  ${two(d.hour)}:'
        '${two(d.minute)}';
  }
}
