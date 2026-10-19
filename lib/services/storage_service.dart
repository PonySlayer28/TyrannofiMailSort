import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_config.dart';
import '../models/mail_server.dart';
import '../models/results.dart';
import '../models/sort_rule.dart';
import '../utils/domain_utils.dart';
import '../utils/folder_merge.dart';

/// Local persistence: Hive for configs / blacklist / caches / sort progress,
/// flutter_secure_storage for passwords.
///
/// Replaces the file-based storage (config_path, keyring, progress files …)
/// from gmail_app.py.
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const _folderCacheTtl = Duration(hours: 24);

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  late Box _configBox; // serverKey -> config json string
  late Box _blacklistBox; // entry -> {type, note, added}
  late Box _folderCacheBox; // serverKey -> {ts, folders}
  late Box _progressBox; // serverKey -> List<int> done uids
  late Box _miscBox; // disposable domains + flags

  Future<void> init() async {
    await Hive.initFlutter();
    _configBox = await Hive.openBox('configs');
    _blacklistBox = await Hive.openBox('blacklist');
    _folderCacheBox = await Hive.openBox('folder_cache');
    _progressBox = await Hive.openBox('sort_progress');
    _miscBox = await Hive.openBox('misc');
    await _seedOnFirstRun();
  }

  /// On the very first launch, import the bundled starter spam blacklist.
  /// No account configs are seeded — every install starts with no accounts
  /// and no personal data.
  Future<void> _seedOnFirstRun() async {
    if (_miscBox.get('seeded') == true) return;
    if (_blacklistBox.isEmpty) {
      try {
        final raw = await rootBundle.loadString('assets/seed/blacklist.json');
        final Map data = jsonDecode(raw) as Map;
        for (final e in data.entries) {
          _blacklistBox.put(e.key, Map<String, dynamic>.from(e.value as Map));
        }
      } catch (_) {}
    }
    await _miscBox.put('seeded', true);
  }

  // ── Config ────────────────────────────────────────────────
  /// The last selected provider.
  ///
  /// Without it every launch starts at Gmail, and anyone who configured a
  /// different mailbox reads "No account configured" — which looks like data
  /// loss even though only the selection is off.
  String get lastServerKey =>
      validServerKey(_miscBox.get('server_key') as String?);

  Future<void> saveLastServerKey(String serverKey) =>
      _miscBox.put('server_key', serverKey);

  AppConfig loadConfig(String serverKey) {
    final raw = _configBox.get(serverKey);
    if (raw is String && raw.isNotEmpty) {
      try {
        return AppConfig.fromJson(serverKey, jsonDecode(raw) as Map);
      } catch (_) {}
    }
    return AppConfig.defaults(serverKey);
  }

  Future<void> saveConfig(AppConfig config) async {
    await _configBox.put(config.serverKey, jsonEncode(config.toJson()));
    invalidateFolderCache(config.serverKey);
  }

  // ── Rules helpers (mirror get_all_rules / add / delete / toggle / dedup) ──
  List<SortRule> allRules(String sk) => loadConfig(sk).allRules;
  List<SortRule> activeRules(String sk) => loadConfig(sk).activeRules;

  /// Add a rule. Returns null on success, an error message on duplicate.
  Future<String?> addRule(String sk, String name, String from, String folder) async {
    final cfg = loadConfig(sk);
    final existing = cfg.allRules.map((r) => r.matchFrom.toLowerCase()).toSet();
    if (existing.contains(from.toLowerCase())) {
      return "Rule '$from' already exists!";
    }
    cfg.rules.add(SortRule(
      name: name.isNotEmpty ? name : '$from -> $folder',
      matchFrom: from,
      moveTo: folder,
    ));
    await saveConfig(cfg);
    return null;
  }

  Future<void> deleteRule(String sk, int index) async {
    final cfg = loadConfig(sk);
    final valid = cfg.allRules;
    if (index >= 0 && index < valid.length) {
      cfg.rules.remove(valid[index]);
      await saveConfig(cfg);
    }
  }

  Future<bool> toggleRule(String sk, int index) async {
    final cfg = loadConfig(sk);
    final valid = cfg.allRules;
    if (index >= 0 && index < valid.length) {
      valid[index].enabled = !valid[index].enabled;
      await saveConfig(cfg);
      return valid[index].enabled;
    }
    return false;
  }

  /// Drop every rule at once. Returns how many went.
  ///
  /// Deleting 501 rules one tap at a time is not a thing anyone does, so
  /// without this the list could only grow. Kept apart from `deleteRule`
  /// rather than folded into it: this is the one rule operation that cannot be
  /// undone by remembering what was on screen a second ago.
  ///
  /// What it costs is worth saying plainly, because the screen has to say it
  /// too: in sender mode the rules are already unread, so nothing about
  /// sorting changes today. What goes is the way back. Until now, switching
  /// `sortBySender` off returned the hand-kept list unharmed; afterwards it
  /// returns an empty one.
  Future<int> clearRules(String sk) async {
    final cfg = loadConfig(sk);
    final had = cfg.rules.length;
    if (had == 0) return 0;
    cfg.rules = [];
    await saveConfig(cfg);
    return had;
  }

  /// Remove rules with duplicate match-from patterns. Returns count removed.
  Future<int> dedupRules(String sk) async {
    final cfg = loadConfig(sk);
    final seen = <String>{};
    final clean = <SortRule>[];
    var removed = 0;
    for (final r in cfg.rules) {
      final key = r.matchFrom.toLowerCase();
      if (seen.contains(key)) {
        removed++;
      } else {
        seen.add(key);
        clean.add(r);
      }
    }
    cfg.rules = clean;
    await saveConfig(cfg);
    return removed;
  }

  /// Create rules for every scanned domain not already covered.
  ///
  /// Pass [existingFolders] so a domain that already has a home lands there
  /// instead of getting a second one invented for it. Without it this method is
  /// what created the duplicate structure in the first place: it derived
  /// `Amazon` from `amazon.de` while `Shopping/Amazon` already existed, and both
  /// then filled up in parallel.
  Future<int> autoAssign(String sk, ScanResult scan,
      {List<String> existingFolders = const []}) async {
    final cfg = loadConfig(sk);
    final existing = cfg.allRules.map((r) => r.matchFrom.toLowerCase()).toList();
    final usable = existingFolders.where((f) => !f.startsWith('['));
    final byLeaf = <String, String>{};
    // Categorised folders claim their name first: with both `Amazon` and
    // `Shopping/Amazon` present, mail for amazon.de belongs in the categorised
    // one, and offering the flat one as a target would rebuild the duplication.
    for (final f in usable.where((f) => f.contains('/'))) {
      byLeaf.putIfAbsent(folderKey(f.split('/').last), () => f);
    }
    for (final f in usable.where((f) => !f.contains('/'))) {
      byLeaf.putIfAbsent(folderKey(f), () => f);
    }
    var added = 0;
    for (final d in scan.domains) {
      final domain = d.domain;
      if (domain.isEmpty) continue;
      var pattern = domain.contains('.') ? domain.split('.').first : domain;
      if (pattern.length <= 2) pattern = domain;
      if (existing.any((p) => patternMatchesDomain(p, domain))) continue;
      final folder =
          byLeaf[folderKey(_domainToFolder(domain))] ?? _domainToFolder(domain);
      cfg.rules.add(SortRule(
        name: '$domain -> $folder',
        matchFrom: pattern,
        moveTo: folder,
      ));
      existing.add(pattern.toLowerCase());
      added++;
    }
    await saveConfig(cfg);
    return added;
  }

  /// Point every rule naming [source] at [target] instead.
  ///
  /// Called right after a merge deletes [source]: a rule still naming it would
  /// recreate the folder on the next sort and undo the merge. Rules that would
  /// then duplicate an existing one (same pattern, same target) are dropped
  /// rather than left to fire twice. Returns how many rules were changed.
  Future<int> repointRules(String sk, String source, String target) async {
    final cfg = loadConfig(sk);
    var changed = 0;
    for (final r in cfg.rules) {
      if (r.moveTo != source) continue;
      r.moveTo = target;
      if (r.name.endsWith('-> $source')) {
        r.name = '${r.name.substring(0, r.name.length - source.length)}$target';
      }
      changed++;
    }
    if (changed == 0) return 0;
    final seen = <String>{};
    cfg.rules = cfg.rules
        .where((r) => seen.add('${r.matchFrom.toLowerCase()}\u0000${r.moveTo}'))
        .toList();
    await saveConfig(cfg);
    return changed;
  }

  /// Apply [repairs] from `planRuleRepairs`, dropping rules that would then
  /// duplicate another. Returns how many rules were repointed.
  Future<int> applyRuleRepairs(String sk, List<RuleRepair> repairs) async {
    if (repairs.isEmpty) return 0;
    final byTarget = <String, String>{
      for (final r in repairs) r.rule.moveTo: r.newTarget
    };
    final cfg = loadConfig(sk);
    var changed = 0;
    for (final r in cfg.rules) {
      final target = byTarget[r.moveTo];
      if (target == null) continue;
      final old = r.moveTo;
      r.moveTo = target;
      if (r.name.endsWith('-> $old')) {
        r.name = '${r.name.substring(0, r.name.length - old.length)}$target';
      }
      changed++;
    }
    final seen = <String>{};
    cfg.rules = cfg.rules
        .where((r) => seen.add('${r.matchFrom.toLowerCase()}\u0000${r.moveTo}'))
        .toList();
    await saveConfig(cfg);
    return changed;
  }

  /// Write the Message-IDs that were in [folder] to a timestamped JSON file
  /// before a merge moves them away, and return its path.
  ///
  /// This is the only record that survives the merge: the server keeps no
  /// history of which folder a mail came from, so without this the old grouping
  /// is simply gone. Kept as a plain file rather than in Hive so it can be
  /// pulled off the device and used independently of the app.
  Future<String> saveMergeBackup(
      String sk, String folder, List<String> messageIds) async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}'
        '/merge_backups');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .split('-')
        .take(6)
        .join('-');
    final safe = folder.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    final file = File('${dir.path}/${stamp}_$safe.json');
    await file.writeAsString(jsonEncode({
      'serverKey': sk,
      'folder': folder,
      'savedAt': DateTime.now().toIso8601String(),
      'count': messageIds.length,
      'messageIds': messageIds,
    }));
    return file.path;
  }

  /// Every backup written so far, newest first.
  ///
  /// The files are the only record of which folder a mail came from — the
  /// server keeps none. Listing them is what makes that record real for
  /// someone without a cable and a shell: until this, the promise in the merge
  /// dialog was true but unreachable.
  Future<List<BackupFile>> listBackups() async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}'
        '/merge_backups');
    if (!dir.existsSync()) return [];
    final out = <BackupFile>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map;
        out.add(BackupFile(
          path: f.path,
          // Merge backups name their folder; the pre-rename snapshot has none.
          folder: j['folder']?.toString() ?? 'Folder list',
          count: (j['count'] as num?)?.toInt() ?? 0,
          savedAt: DateTime.tryParse((j['savedAt'] ?? '').toString()),
        ));
      } catch (_) {
        // A file we cannot read is still worth listing — better a line the
        // user can export than a silent gap in their record.
        out.add(BackupFile(path: f.path, folder: '', count: 0, savedAt: null));
      }
    }
    out.sort((a, b) => b.path.compareTo(a.path));
    return out;
  }

  /// Record the folder tree before a bulk rename or delete, and return the
  /// file's path. Names and counts only — enough to rebuild the structure or to
  /// see what was lost, not enough to put individual mails back.
  Future<String> saveFolderSnapshot(String sk, Map<String, int> folders) async {
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}'
        '/merge_backups');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .split('-')
        .take(6)
        .join('-');
    final file = File('${dir.path}/${stamp}_folder_list.json');
    await file.writeAsString(jsonEncode({
      'serverKey': sk,
      'savedAt': DateTime.now().toIso8601String(),
      'count': folders.length,
      'folders': folders,
    }));
    return file.path;
  }

  /// Turn already-sorted folders into rules: for every folder → domain pairing
  /// that clears the threshold, add a rule pointing that domain at the folder
  /// it is already sitting in — for inboxes sorted by hand before this app
  /// existed.
  ///
  /// The threshold follows [sampleSize] rather than being passed separately.
  /// Demanding two sightings only filters out misfiled one-offs when the sample
  /// is large enough to have two; with a one-mail sample every count is 1 and a
  /// fixed threshold of 2 silently discarded every rule.
  Future<int> importRulesFromFolders(
      String sk, Map<String, Map<String, int>> folderDomains,
      {required int sampleSize}) async {
    final minCount = sampleSize > 0 && sampleSize < 3 ? 1 : 2;
    final cfg = loadConfig(sk);
    final existing = cfg.allRules.map((r) => r.matchFrom.toLowerCase()).toList();
    var added = 0;
    for (final folderEntry in folderDomains.entries) {
      final folder = folderEntry.key;
      final byCount = folderEntry.value.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final d in byCount) {
        final domain = d.key;
        final count = d.value;
        if (count < minCount) continue;
        var pattern = domain.contains('.') ? domain.split('.').first : domain;
        if (pattern.length <= 2) pattern = domain;
        if (existing.any((p) => patternMatchesDomain(p, domain))) continue;
        cfg.rules.add(SortRule(
          name: '$domain -> $folder',
          matchFrom: pattern,
          moveTo: folder,
        ));
        existing.add(pattern.toLowerCase());
        added++;
      }
    }
    await saveConfig(cfg);
    return added;
  }

  String _domainToFolder(String domain) {
    final name = domain.contains('.') ? domain.split('.').first : domain;
    if (name.isEmpty) return domain;
    return name[0].toUpperCase() + name.substring(1);
  }

  // ── Passwords (secure storage) ────────────────────────────
  Future<void> savePassword(String sk, String email, String password) async {
    if (email.isEmpty || password.isEmpty) return;
    await _secure.write(key: 'pw:$sk:$email', value: password);
  }

  Future<String> loadPassword(String sk, String email) async {
    if (email.isEmpty) return '';
    return await _secure.read(key: 'pw:$sk:$email') ?? '';
  }

  Future<void> deletePassword(String sk, String email) async {
    if (email.isEmpty) return;
    await _secure.delete(key: 'pw:$sk:$email');
  }

  // ── Custom blacklist ──────────────────────────────────────
  Map<String, Map> loadBlacklist() {
    final out = <String, Map>{};
    for (final key in _blacklistBox.keys) {
      final v = _blacklistBox.get(key);
      if (v is Map) out['$key'] = v;
    }
    return out;
  }

  /// Returns null on success, error message otherwise.
  Future<String?> blacklistAdd(String entry, {String note = ''}) async {
    entry = entry.toLowerCase().trim();
    if (entry.isEmpty) return 'Empty input';
    if (_blacklistBox.containsKey(entry)) return "'$entry' is already in the list";
    await _blacklistBox.put(entry, {
      'type': entry.contains('@') ? 'email' : 'domain',
      'note': note,
      'added': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    return null;
  }

  Future<void> blacklistRemove(String entry) async {
    await _blacklistBox.delete(entry.toLowerCase().trim());
  }

  // ── Folder cache ──────────────────────────────────────────
  List<FolderInfo>? loadFolderCache(String sk, {bool allowStale = false}) {
    final data = _folderCacheBox.get(sk);
    if (data is Map) {
      final ts = data['ts'] is int ? data['ts'] as int : 0;
      final folders = (data['folders'] as List?)
              ?.map((e) => FolderInfo.fromJson(e as Map))
              .toList() ??
          [];
      if (folderCacheIsFresh(ts, DateTime.now().millisecondsSinceEpoch,
          _folderCacheTtl)) {
        return folders;
      }
      if (allowStale && folders.isNotEmpty) return folders;
    }
    return null;
  }

  Future<void> saveFolderCache(String sk, List<FolderInfo> folders) async {
    await _folderCacheBox.put(sk, {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'folders': folders.map((f) => f.toJson()).toList(),
    });
  }

  /// Mark the cached folder list as out of date — it is, the moment a merge or
  /// a re-sort has moved anything.
  ///
  /// Marks rather than deletes, and that is the whole point: a deleted entry
  /// leaves `allowStale: true` with nothing to return, so the one caller that
  /// asks for old-but-better-than-nothing gets nothing. That is why the
  /// re-sort screen lost every mail count after its first run, and why a
  /// failed LIST showed an error instead of the list from a minute ago.
  ///
  /// Nothing is loosened by this. The plain read still returns null — a
  /// timestamp of zero is older than any TTL — so `known`, `created` and every
  /// other caller that must not believe the cache still cannot (bug 11).
  /// Only the callers that explicitly ask for stale data get it.
  void invalidateFolderCache(String sk) {
    final data = _folderCacheBox.get(sk);
    if (data is! Map) return;
    _folderCacheBox.put(sk, staleFolderCacheEntry(data));
  }

  // ── Sort progress (resumable) ─────────────────────────────
  Set<int> loadProgress(String sk) {
    final data = _progressBox.get(sk);
    if (data is List) return data.map((e) => e as int).toSet();
    return {};
  }

  Future<void> saveProgress(String sk, Set<int> doneUids) async {
    await _progressBox.put(sk, doneUids.toList());
  }

  Future<void> clearProgress(String sk) async {
    await _progressBox.delete(sk);
  }

  // ── Resort progress (resumable) ───────────────────────────
  //
  // The inbox sort has been resumable from the start, because it walks UIDs
  // and can remember the ones it is done with. The tree rebuild walks folders
  // and remembered nothing: five hours of work, and an interruption started
  // over at the first folder. The foreground service (bug 15) made that
  // unlikely, not impossible — and "unlikely over five hours" is not the same
  // as safe.
  //
  // Kept in the same box as the UID progress under its own key, so an account
  // has one place where "what is already done" lives.
  static String _resortKey(String sk) => '$sk::resort';

  /// Folders a running rebuild has already finished.
  Set<String> loadResortProgress(String sk) {
    final data = _progressBox.get(_resortKey(sk));
    if (data is List) return data.map((e) => '$e').toSet();
    return {};
  }

  Future<void> saveResortProgress(String sk, Set<String> doneFolders) async {
    await _progressBox.put(_resortKey(sk), doneFolders.toList());
  }

  /// Forget it — a finished run leaves nothing for the next one to skip.
  Future<void> clearResortProgress(String sk) async {
    await _progressBox.delete(_resortKey(sk));
  }

  // ── Disposable domains cache ──────────────────────────────
  Set<String> get disposableDomains {
    final data = _miscBox.get('disposable_domains');
    if (data is List) return data.map((e) => '$e').toSet();
    return {};
  }

  int get disposableTs => _miscBox.get('disposable_ts', defaultValue: 0) as int;

  Future<void> saveDisposable(Set<String> domains) async {
    await _miscBox.put('disposable_domains', domains.toList());
    await _miscBox.put(
        'disposable_ts', DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }
}

/// May a cached folder list still be believed without asking for it?
///
/// Pulled out of [StorageService.loadFolderCache] as a pure function because
/// the answer for an invalidated entry is a promise, not a detail: it carries
/// a timestamp of zero and must come back false for every conceivable clock,
/// or the cache trap of bug 11 reopens — `known` and `created` seeded from
/// folders a merge deleted, and every mail heading there left behind without
/// an error.
bool folderCacheIsFresh(int ts, int nowMs, Duration ttl) =>
    nowMs - ts < ttl.inMilliseconds;

/// What an invalidated entry turns into: the same folder list, no timestamp.
///
/// The list is kept so `allowStale: true` has something to hand back — the
/// re-sort screen's mail counts and the fallback for a failed LIST. Deleting
/// the entry, as this used to, made that parameter a promise the store could
/// never keep.
Map<String, dynamic> staleFolderCacheEntry(Map data) =>
    {'ts': 0, 'folders': data['folders'] ?? const []};
