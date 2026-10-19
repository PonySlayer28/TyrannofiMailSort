import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';

import '../models/app_config.dart';
import '../models/results.dart';
import '../models/sort_rule.dart';
import '../utils/domain_utils.dart';
import '../utils/imap_path.dart';
import '../utils/folder_merge.dart';
import 'long_run_guard.dart';
import 'spam_service.dart';
import 'storage_service.dart';

typedef ProgressCb = void Function(OpProgress p);

/// Native IMAP operations, ported from gmail_app.py using the `enough_mail`
/// package. All methods connect, work, and log out — the app never keeps a
/// long-lived connection (matches the original request/response model).
class ImapService {
  ImapService._();
  static final ImapService instance = ImapService._();

  final _storage = StorageService.instance;
  final _spam = SpamService.instance;

  // Fetch definitions.
  static const _fHeadersFromSubj = 'BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)]';
  static const _fHeadersSort = 'BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT)]';
  static const _fHeadersFrom = 'BODY.PEEK[HEADER.FIELDS (FROM)]';
  static const _fHeadersDupe =
      'BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)]';
  static const _fHeadersMsgId = 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]';
  static const _fInboxList =
      '(UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)])';
  static const _fFull = '(UID FLAGS BODY[])';

  static const _gmailSkipPrefix = '[Gmail]/';
  static const _googleMailPrefix = '[Google Mail]/';

  /// googlemail.com accounts report Gmail's virtual folders as
  /// `[Google Mail]/…` instead of `[Gmail]/…`. Normalise to the `[Gmail]/`
  /// spelling so every skip list below matches either variant — otherwise
  /// All Mail, Sent, Trash and Spam are treated as ordinary folders.
  String _normalizePath(String path) => path.startsWith(_googleMailPrefix)
      ? '$_gmailSkipPrefix${path.substring(_googleMailPrefix.length)}'
      : path;

  /// Mailboxes the server itself marks as special-use (Sent, Trash, Junk,
  /// Drafts, Archive), plus Gmail's All Mail and Starred views. Never a valid
  /// source for rules or a sorting target.
  bool _isSpecialUseMailbox(Mailbox box) =>
      box.isSpecialUse ||
      box.hasFlag(MailboxFlag.all) ||
      box.hasFlag(MailboxFlag.flagged);

  /// Anything filed under a bracketed top-level segment — `[Gmail]/…`,
  /// `[Google Mail]/…`, `[Imap]/…`. Providers use that shape for their own
  /// views and migration leftovers, and matching the shape rather than a list
  /// of known names means the next provider's spelling is covered too. The
  /// earlier per-name skip list missed `[Imap]/Papierkorb`, `[Imap]/Entwürfe`
  /// and `[Imap]/Gesendet`, which then turned into sorting rules.
  bool _isProviderNamespace(String path) => path.startsWith('[');

  bool _supportsMove = false;

  // ── Connection ────────────────────────────────────────────
  Future<ImapClient> _connect(AppConfig cfg, String password) async {
    if (cfg.email.isEmpty) throw ImapFailure('No email address configured.');
    if (password.isEmpty) throw ImapFailure('No password set.');
    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(cfg.imapServer, cfg.imapPort, isSecure: true);
      final caps = await client.login(cfg.email, password);
      _supportsMove = caps.any((c) => c.name.toUpperCase() == 'MOVE');
      // Only after the login succeeded: a connection that never came up has no
      // work to protect, and counting it would strand the guard.
      LongRunGuard.begin();
      return client;
    } on ImapException catch (e) {
      throw ImapFailure('IMAP error: ${e.message}');
    } catch (e) {
      throw ImapFailure(_clean(e));
    }
  }

  Future<void> _logout(ImapClient client) async {
    try {
      await client.logout();
    } catch (_) {}
    // In the same place as the logout, so the protection ends with the work
    // even when the operation above threw.
    await LongRunGuard.end();
  }

  String _clean(Object e) {
    var s = e.toString();
    if (s.startsWith('Exception: ')) s = s.substring(11);
    return s;
  }

  /// Verify credentials for the settings screen.
  Future<void> testConnection(AppConfig cfg, String password) async {
    final client = await _connect(cfg, password);
    await _logout(client);
  }

  // ── Helpers ───────────────────────────────────────────────
  Future<List<int>> _searchAll(ImapClient client) async {
    final res = await client.uidSearchMessages(searchCriteria: 'ALL');
    return res.matchingSequence?.toList() ?? const [];
  }

  /// The character this server puts between a folder and its child.
  ///
  /// It arrives with the first `LIST`; before that it is unknown, and guessing
  /// `/` would split a path wrongly on a server that uses `.`. Asking costs one
  /// round trip on the first call of a session and nothing afterwards — the
  /// same thing `selectMailboxByPath` does internally.
  Future<String> _pathSeparator(ImapClient client) async {
    if (client.serverInfo.pathSeparator == null) {
      await client.listMailboxes();
    }
    return client.serverInfo.pathSeparator ?? '/';
  }

  /// Select [path], written the way IMAP wants it.
  ///
  /// `selectMailboxByPath` hands its argument straight to the server — the
  /// argument *is* the wire form. Every path here comes from `Mailbox.path`
  /// and is decoded, so it has to be encoded back. Without this a folder with
  /// an umlaut answers `BAD Could not parse command`. See `imap_path.dart`.
  Future<Mailbox> _selectPath(ImapClient client, String path) async =>
      client.selectMailboxByPath(
          encodeMailboxPath(path, await _pathSeparator(client)));

  /// Create [path]. `createMailbox` encodes the last segment itself, so only
  /// what sits above it is encoded here — encoding all of it would encode that
  /// last segment twice.
  Future<Mailbox> _createPath(ImapClient client, String path) async =>
      client.createMailbox(
          encodeMailboxParents(path, await _pathSeparator(client)));

  String _senderEmail(MimeMessage msg) {
    final from = msg.from;
    if (from != null && from.isNotEmpty) return from.first.email.toLowerCase();
    return '';
  }

  String _fromDisplay(MimeMessage msg) {
    final from = msg.from;
    if (from != null && from.isNotEmpty) {
      final a = from.first;
      final name = a.personalName?.trim() ?? '';
      return name.isNotEmpty ? name : a.email;
    }
    return '';
  }

  /// Move a single UID (currently-selected mailbox) to [targetPath].
  /// Uses MOVE when available, otherwise COPY + mark \Deleted.
  Future<bool> _moveUid(ImapClient client, int uid, String targetPath) async {
    final seq = MessageSequence.fromIds([uid], isUid: true);
    // MOVE and COPY encode the target's last segment themselves; anything
    // above it is ours to encode, or `Bücher/Amazon` breaks the command.
    final target =
        encodeMailboxParents(targetPath, await _pathSeparator(client));
    if (_supportsMove) {
      try {
        await client.uidMove(seq, targetMailboxPath: target);
        return true;
      } catch (_) {}
    }
    try {
      await client.uidCopy(seq, targetMailboxPath: target);
      await client.uidStore(seq, [MessageFlags.deleted], action: StoreAction.add);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Which rule (if any) matches this sender address? Returns target folder.
  /// The port matches only against the "from" field, like gmail_app.py rules.
  String? _matchRule(String fromAddr, List<SortRule> rules) {
    for (final r in rules) {
      if (patternMatchesSender(r.matchFrom, fromAddr)) return r.moveTo;
    }
    return null;
  }

  /// Where this mail belongs, under whichever law [cfg] is set to.
  ///
  /// With [AppConfig.sortBySender] the rule list is not consulted — the sender
  /// decides, and an unknown sender gets a folder rather than no match. That
  /// is the point of the mode: a tree rebuilt by sender and an inbox sorted by
  /// rules would drift apart again with the first mail from a new domain.
  String? _sortTarget(AppConfig cfg, String fromAddr, List<SortRule> rules) =>
      cfg.sortBySender ? senderFolder(fromAddr) : _matchRule(fromAddr, rules);

  Iterable<List<int>> _chunks(List<int> list, int size) sync* {
    for (var i = 0; i < list.length; i += size) {
      yield list.sublist(i, i + size > list.length ? list.length : i + size);
    }
  }

  // ── 2. SCAN INBOX ─────────────────────────────────────────
  Future<ScanResult> scanInbox(AppConfig cfg, String password,
      {ProgressCb? onProgress, String folder = 'INBOX'}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    try {
      await _selectPath(client, folder);
      final uids = await _searchAll(client);
      final total = uids.length;
      onProgress?.call(OpProgress(
          status: 'running', total: total, message: 'Scanning $total mails...'));

      final domainCount = <String, int>{};
      final domainSenders = <String, Set<String>>{};
      final senderSubjects = <String, List<String>>{};
      var processed = 0;
      var current = 0;

      for (final chunk in _chunks(uids, 200)) {
        final seq = MessageSequence.fromIds(chunk, isUid: true);
        final res = await client.uidFetchMessages(seq, _fHeadersFromSubj);
        for (final msg in res.messages) {
          final sender = _senderEmail(msg);
          final dom = domainOf(sender);
          if (dom.isEmpty) continue;
          final base = extractBaseDomain(dom);
          domainCount[base] = (domainCount[base] ?? 0) + 1;
          (domainSenders[base] ??= {}).add(sender);
          final subj = msg.decodeSubject() ?? '';
          final list = senderSubjects[sender] ??= [];
          if (list.length < 3) list.add(subj.length > 80 ? subj.substring(0, 80) : subj);
          processed++;
        }
        current += chunk.length;
        onProgress?.call(OpProgress(
            status: 'running',
            current: current,
            total: total,
            message: 'Scanning $current/$total...'));
      }

      final sorted = domainCount.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final domains = <DomainScanEntry>[];
      for (final e in sorted.take(500)) {
        final senders = (domainSenders[e.key] ?? {}).take(5).toList();
        final examples = <String>[];
        for (final s in senders) {
          final subs = senderSubjects[s];
          if (subs != null && subs.isNotEmpty) examples.add(subs.first);
        }
        domains.add(DomainScanEntry(
          domain: e.key,
          count: e.value,
          senders: senders,
          examples: examples.take(2).toList(),
        ));
      }

      onProgress?.call(OpProgress(
          status: 'done',
          current: total,
          total: total,
          message: 'Done! $processed mails, ${domains.length} domains.'));
      return ScanResult(domains: domains, total: total, analyzed: processed);
    } finally {
      await _logout(client);
    }
  }

  // ── LIST FOLDERS ──────────────────────────────────────────
  Future<List<FolderInfo>> listFolders(AppConfig cfg, String password,
      {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _storage.loadFolderCache(cfg.serverKey);
      if (cached != null) return cached;
    }
    ImapClient? client;
    try {
      client = await _connect(cfg, password);
      final boxes = await client.listMailboxes(recursive: true);
      final folders = <FolderInfo>[];
      for (final box in boxes) {
        if (box.isNotSelectable) continue;
        final name = box.path;
        if (_isProviderNamespace(name)) continue;
        var count = 0;
        try {
          final status = await client.statusMailbox(box, [StatusFlags.messages]);
          count = status.messagesExists;
        } catch (_) {}
        if (count > 0) folders.add(FolderInfo(name: name, count: count));
      }
      folders.sort((a, b) => b.count.compareTo(a.count));
      await _storage.saveFolderCache(cfg.serverKey, folders);
      return folders;
    } catch (e) {
      final stale = _storage.loadFolderCache(cfg.serverKey, allowStale: true);
      if (stale != null) return stale;
      throw ImapFailure(_clean(e));
    } finally {
      if (client != null) await _logout(client);
    }
  }

  /// Rules pointing at folders that no longer exist, with the folder each
  /// should point at instead. Empty when there is nothing to repair.
  ///
  /// Asked before sorting as well as on the folder screen: applying such a
  /// rule recreates the folder a merge just deleted, so a sort run started in
  /// this state works against the merge that preceded it. Uses the cached
  /// folder list — this is a guard, not a reason to go to the server again.
  Future<List<RuleRepair>> pendingRuleRepairs(
      AppConfig cfg, String password) async {
    final folders = await listFolders(cfg, password);
    return planRuleRepairs(_storage.allRules(cfg.serverKey),
        folders.map((f) => f.name).toList());
  }

  /// How many of the newest mails per folder rule discovery looks at.
  /// A hand-sorted folder holds one sender — its newest mail already names
  /// that sender, so one mail per folder is the whole sample. Reading more
  /// only re-confirms it, and across hundreds of folders that costs minutes.
  static const defaultRuleSampleSize = 1;

  // ── FOLDER RULE IMPORT — count sender domains in every existing,
  // non-INBOX folder so already-sorted mailboxes can be turned into rules.
  // Only the newest [sampleSize] mails per folder are read; pass 0 to read
  // every mail.
  Future<Map<String, Map<String, int>>> scanFoldersForRuleImport(
      AppConfig cfg, String password,
      {ProgressCb? onProgress, int sampleSize = defaultRuleSampleSize}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    const skip = {
      'INBOX',
      '[Gmail]/Alle Nachrichten', '[Gmail]/All Mail',
      '[Gmail]/Spam', '[Gmail]/Papierkorb', '[Gmail]/Trash', '[Gmail]/Bin',
      '[Gmail]/Wichtig', '[Gmail]/Important', '[Gmail]/Markiert',
      '[Gmail]/Starred', '[Gmail]/Entwürfe', '[Gmail]/Drafts',
      '[Gmail]/Gesendet', '[Gmail]/Sent Mail',
      'Trash', 'Papierkorb', 'Sent', 'Gesendet', 'Sent Items',
      'Sent Messages', 'Drafts', 'Entwürfe', 'Junk', 'Junk E-mail', 'Spam',
    };
    try {
      final boxes = await client.listMailboxes(recursive: true);
      final folders = boxes
          .where((b) =>
              !b.isNotSelectable &&
              !_isSpecialUseMailbox(b) &&
              !_isProviderNamespace(b.path) &&
              !skip.contains(_normalizePath(b.path)))
          .map((b) => b.path)
          .toList();
      onProgress?.call(const OpProgress().running(sampleSize == 1
          ? '${folders.length} folders. Checking newest mail each...'
          : sampleSize > 0
              ? '${folders.length} folders. Checking $sampleSize newest mails each...'
              : '${folders.length} folders. Analyzing...'));

      final result = <String, Map<String, int>>{};
      var current = 0;
      for (final folder in folders) {
        int exists;
        try {
          final box = await _selectPath(client, folder);
          exists = box.messagesExists;
        } catch (_) {
          continue;
        }
        if (exists == 0) continue;
        // The newest mails carry the highest sequence numbers, so the sample is
        // simply the tail of the mailbox — and SELECT already told us how long
        // it is. Going through UID SEARCH instead would drag all 40k UIDs of a
        // big folder over the wire only to discard all but the last few hundred.
        final first = (sampleSize > 0 && exists > sampleSize)
            ? exists - sampleSize + 1
            : 1;
        final domainCounts = <String, int>{};
        for (var start = first; start <= exists; start += 200) {
          final end = (start + 199 > exists) ? exists : start + 199;
          final res = await client.fetchMessages(
              MessageSequence.fromRange(start, end), _fHeadersFrom);
          for (final msg in res.messages) {
            final base = extractBaseDomain(domainOf(_senderEmail(msg)));
            if (base.isEmpty) continue;
            domainCounts[base] = (domainCounts[base] ?? 0) + 1;
          }
        }
        if (domainCounts.isNotEmpty) result[folder] = domainCounts;
        current++;
        onProgress?.call(OpProgress(
            status: 'running',
            current: current,
            total: folders.length,
            message: 'Analyzing folders... $current/${folders.length}'));
      }
      onProgress?.call(OpProgress(
          status: 'done',
          message: 'Done! ${result.length} folders with content.'));
      return result;
    } finally {
      await _logout(client);
    }
  }

  // ── 3. SCAN FOLDER (which domains, which are misplaced) ───
  Future<FolderScanResult> scanFolder(
      AppConfig cfg, String password, String folder,
      {ProgressCb? onProgress}) async {
    onProgress?.call(const OpProgress().running('Scanning $folder...'));
    final client = await _connect(cfg, password);
    final rules = cfg.activeRules;
    try {
      await _selectPath(client, folder);
      final uids = await _searchAll(client);
      final total = uids.length;
      onProgress?.call(OpProgress(status: 'running', total: total));

      final domainMails = <String, List<Map<String, dynamic>>>{};
      var processed = 0;
      var current = 0;

      for (final chunk in _chunks(uids, 200)) {
        final seq = MessageSequence.fromIds(chunk, isUid: true);
        final res = await client.uidFetchMessages(seq, _fHeadersFromSubj);
        for (final msg in res.messages) {
          final sender = _senderEmail(msg);
          final dom = domainOf(sender);
          final base = extractBaseDomain(dom);
          final subj = msg.decodeSubject() ?? '';
          final matched = _matchRule(sender, rules);
          final belongsHere = matched == folder ||
              (matched == domainToFolder(base) &&
                  domainToFolder(base) == folder.split('/').last);
          final isWrong =
              matched != null && matched != folder && !belongsHere;
          (domainMails[base] ??= []).add({
            'subject': subj.length > 60 ? subj.substring(0, 60) : subj,
            'should_be': matched ?? '?',
            'wrong': isWrong,
          });
          processed++;
        }
        current += chunk.length;
        onProgress?.call(OpProgress(
            status: 'running',
            current: current,
            total: total,
            message: 'Scanning $folder... $current/$total'));
      }

      final entries = domainMails.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      final results = <FolderDomainEntry>[];
      var wrongCount = 0;
      for (final e in entries) {
        final wrongMails = e.value.where((m) => m['wrong'] == true).toList();
        wrongCount += wrongMails.length;
        results.add(FolderDomainEntry(
          domain: e.key,
          count: e.value.length,
          wrongCount: wrongMails.length,
          shouldBe:
              wrongMails.isNotEmpty ? wrongMails.first['should_be'] : folder,
          examples:
              e.value.take(2).map((m) => m['subject'] as String).toList(),
        ));
      }

      onProgress?.call(OpProgress(
          status: 'done',
          current: total,
          total: total,
          message: 'Done! $processed mails, $wrongCount misplaced.'));
      return FolderScanResult(
          folder: folder, domains: results, total: processed, wrong: wrongCount);
    } finally {
      await _logout(client);
    }
  }

  // ── FOLDER MERGE — fold a duplicate folder into the one it duplicates ─

  /// Every Message-ID in [folder], in mailbox order.
  ///
  /// Taken before a merge and written to disk: once the mails have moved and
  /// the source folder is gone, nothing on the server still records where they
  /// used to live, and Gmail offers no undo for that. The Message-IDs let the
  /// old grouping be reconstructed by search.
  Future<List<String>> collectMessageIds(
      AppConfig cfg, String password, String folder,
      {ProgressCb? onProgress}) async {
    final client = await _connect(cfg, password);
    try {
      return await _collectMessageIds(client, folder, onProgress: onProgress);
    } finally {
      await _logout(client);
    }
  }

  Future<List<String>> _collectMessageIds(ImapClient client, String folder,
      {ProgressCb? onProgress}) async {
    await _selectPath(client, folder);
    final uids = await _searchAll(client);
    final ids = <String>[];
    var done = 0;
    for (final chunk in _chunks(uids, 200)) {
      final res = await client.uidFetchMessages(
          MessageSequence.fromIds(chunk, isUid: true), _fHeadersMsgId);
      for (final msg in res.messages) {
        final id = msg.getHeaderValue('message-id');
        if (id != null && id.isNotEmpty) ids.add(id);
      }
      done += chunk.length;
      onProgress?.call(OpProgress(
          status: 'running',
          message: 'Saving assignment...',
          current: done,
          total: uids.length));
    }
    return ids;
  }

  /// Move every mail from [source] into [target], then optionally drop the
  /// now-empty [source] mailbox.
  ///
  /// Unlike [moveDomainToFolder] this does not look at senders — the caller has
  /// already established that the two folders mean the same thing, so the whole
  /// mailbox travels. The source is only deleted once every mail moved; a
  /// partial move leaves it in place rather than stranding the remainder.
  Future<MergeResult> mergeFolder(
      AppConfig cfg, String password, String source, String target,
      {bool deleteSource = true, ProgressCb? onProgress}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    try {
      return await _mergeFolder(client, cfg.serverKey, source, target,
          deleteSource: deleteSource, onProgress: onProgress);
    } finally {
      await _logout(client);
    }
  }

  Future<MergeResult> _mergeFolder(
      ImapClient client, String sk, String source, String target,
      {bool deleteSource = true, ProgressCb? onProgress}) async {
    try {
      await _createPath(client, target);
      _storage.invalidateFolderCache(sk);
    } catch (_) {}
    await _selectPath(client, source);
    final uids = await _searchAll(client);
    var moved = 0;
    for (final chunk in _chunks(uids, 200)) {
      for (final uid in chunk) {
        if (await _moveUid(client, uid, target)) moved++;
      }
      onProgress?.call(OpProgress(
          status: 'running',
          message: '$source → $target',
          current: moved,
          total: uids.length));
    }
    try {
      await client.expunge();
    } catch (_) {}

    var deleted = false;
    if (deleteSource && moved == uids.length) {
      try {
        await client.closeMailbox();
      } catch (_) {}
      try {
        await client.deleteMailbox(await _selectPath(client, source));
        deleted = true;
        _storage.invalidateFolderCache(sk);
      } catch (_) {}
    }

    // A rule still naming the source would recreate it on the next sort and
    // undo this merge. Repoint once the mail has actually arrived — not on a
    // partial move, where the source is still the right place for what is left.
    if (moved == uids.length) {
      await _storage.repointRules(sk, source, target);
    }
    return MergeResult(
        source: source,
        target: target,
        moved: moved,
        total: uids.length,
        sourceDeleted: deleted);
  }

  /// Merge many pairs over a single connection.
  ///
  /// One login for the whole run rather than two per pair: at a hundred pairs
  /// the reconnects cost more than the moves, and providers rate-limit logins
  /// long before they rate-limit commands.
  ///
  /// [onSnapshot] is awaited with each source folder's Message-IDs before its
  /// mails move — the run refuses to touch a folder whose record could not be
  /// written. [shouldStop] is consulted between pairs, so a cancel takes effect
  /// at the next folder boundary instead of tearing one in half.
  Future<List<MergeResult>> mergeFolders(
      AppConfig cfg, String password, List<FolderMergePair> pairs,
      {required Future<void> Function(String folder, List<String> ids)
          onSnapshot,
      bool Function()? shouldStop,
      void Function(int done, int total, MergeResult? last)? onPair,
      ProgressCb? onProgress}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    final results = <MergeResult>[];
    try {
      for (final pair in pairs) {
        if (shouldStop?.call() ?? false) break;
        try {
          final ids =
              await _collectMessageIds(client, pair.source, onProgress: (p) {
            onProgress?.call(p);
          });
          await onSnapshot(pair.source, ids);
        } catch (e) {
          // No record written, so this folder stays exactly as it is.
          results.add(MergeResult(
              source: pair.source,
              target: pair.target,
              moved: 0,
              total: pair.sourceCount,
              sourceDeleted: false));
          LongRunGuard.progress('${results.length} of ${pairs.length} pairs');
          onPair?.call(results.length, pairs.length, results.last);
          continue;
        }
        final res = await _mergeFolder(
            client, cfg.serverKey, pair.source, pair.target,
            onProgress: onProgress);
        results.add(res);
        LongRunGuard.progress('${results.length} of ${pairs.length} pairs');
        onPair?.call(results.length, pairs.length, res);
      }
      return results;
    } finally {
      await _logout(client);
    }
  }

  // ── LAST RESORT — bulk rename or delete of every ordinary folder ─

  /// Every ordinary folder: not INBOX, not a provider namespace, not
  /// special-use, and not a reserved name. The set the bulk operations below
  /// act on, and the set [snapshotFolderList] records.
  ///
  /// The name check is the reason this list is trustworthy. The special-use
  /// flag catches drafts and sent mail on servers that set it; this mailbox had
  /// a plain top-level `Entwürfe` that no flag marked, and it went into a
  /// by-sender run as an ordinary folder. Sorting it would have filed unsent
  /// drafts under their recipients' domains, and `deleteAllFolders` would have
  /// deleted it outright.
  Future<List<Mailbox>> _ordinaryMailboxes(ImapClient client) async {
    final boxes = await client.listMailboxes(recursive: true);
    return boxes
        .where((b) =>
            !_isSpecialUseMailbox(b) && !isProtectedMailboxPath(b.path))
        .toList();
  }

  /// Folder names and message counts, for the record kept before a bulk
  /// operation. Cheap — one STATUS per folder, no message bodies — unlike a
  /// full Message-ID snapshot, which for hundreds of folders would take far
  /// longer than the operation it protects.
  Future<Map<String, int>> snapshotFolderList(AppConfig cfg, String password,
      {ProgressCb? onProgress}) async {
    final client = await _connect(cfg, password);
    try {
      final boxes = await _ordinaryMailboxes(client);
      final out = <String, int>{};
      var done = 0;
      for (final box in boxes) {
        try {
          final st = await client.statusMailbox(box, [StatusFlags.messages]);
          out[box.path] = st.messagesExists;
        } catch (_) {
          out[box.path] = -1;
        }
        onProgress?.call(OpProgress(
            status: 'running',
            message: 'Listing folders...',
            current: ++done,
            total: boxes.length));
      }
      return out;
    } finally {
      await _logout(client);
    }
  }

  // ── RESORT — rebuild the whole tree strictly by sender ─

  /// The folders a full re-sort would work through, deepest first.
  ///
  /// Order matters twice. A child must be emptied before its parent, or
  /// deleting the parent fails while the child still hangs under it. And a
  /// hierarchical folder must be handled before the flat folder it feeds:
  /// `Shopping/Amazon` (depth 2) empties into `Amazon` (depth 1), and if
  /// `Amazon` had already been visited and found empty it would be deleted a
  /// moment before receiving them.
  Future<List<String>> resortableFolders(
      AppConfig cfg, String password) async {
    final client = await _connect(cfg, password);
    try {
      final boxes = await _ordinaryMailboxes(client);
      final paths = boxes.map((b) => b.path).toList();
      paths.sort((a, b) {
        final d = b.split('/').length.compareTo(a.split('/').length);
        return d != 0 ? d : a.compareTo(b);
      });
      return paths;
    } finally {
      await _logout(client);
    }
  }

  /// Re-file every mail in [folder] by its sender, then drop the folder if it
  /// emptied.
  ///
  /// This is the one-folder version, meant to be run and read before the batch
  /// is turned loose on the rest.
  Future<ResortResult> resortFolder(
      AppConfig cfg, String password, String folder,
      {bool deleteSource = true, ProgressCb? onProgress}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    try {
      return await _resortFolder(client, cfg.serverKey, folder, <String>{},
          deleteSource: deleteSource, onProgress: onProgress);
    } finally {
      await _logout(client);
    }
  }

  /// Create [target] if it is not there, then return to [reselect].
  ///
  /// Creating a mailbox that already exists is an error the server reports and
  /// we ignore — asking first would cost a round trip per target for no gain.
  /// Reselecting matters: CREATE leaves the selected mailbox undefined on some
  /// servers, and the caller is midway through reading UIDs out of [reselect].
  Future<void> _ensureMailbox(
      ImapClient client, String sk, String target, String reselect) async {
    try {
      await _createPath(client, target);
      _storage.invalidateFolderCache(sk);
    } catch (_) {}
    await _selectPath(client, reselect);
  }

  /// [known] carries the folders this run has already created, so a target is
  /// only created once across a whole batch instead of once per source folder.
  ///
  /// It starts empty rather than seeded from the folder cache: the cache still
  /// lists the flat folders the merges deleted, and those are precisely the
  /// names a by-sender run recreates. Trusting it would skip the CREATE and
  /// leave every one of those mails behind.
  /// [fixedTarget] sends every mail to one place instead of asking the sender.
  /// That is the reset: `INBOX` for all of them, no sorting, no folder
  /// creation. Left null the method behaves exactly as before.
  Future<ResortResult> _resortFolder(
      ImapClient client, String sk, String folder, Set<String> known,
      {bool deleteSource = true,
      String? fixedTarget,
      ProgressCb? onProgress}) async {
    await _selectPath(client, folder);
    final uids = await _searchAll(client);

    // A flat folder already named after the sender domain is its own target.
    // Compared by key rather than exactly: moving `amazon` into `Amazon` would
    // ask the server to move a mail into the folder it is already in, and on
    // Gmail — where labels do not distinguish case — that is a copy followed
    // by a delete of the original.
    final leaf = folder.split('/').last;
    final isFlat = !folder.contains('/');
    final ownKey = folderKey(leaf);

    var moved = 0, toInbox = 0, stayed = 0, batch = 0, seen = 0;

    for (final chunk in _chunks(uids, 200)) {
      final seq = MessageSequence.fromIds(chunk, isUid: true);
      final res = await client.uidFetchMessages(seq, _fHeadersSort);
      for (final msg in res.messages) {
        final uid = msg.uid;
        if (uid == null) continue;

        // Reset: one destination for everything, and the sender is never read.
        // A folder that somehow is its own target is skipped rather than moved
        // into itself — on Gmail that would be a copy plus a delete of the
        // original, not a no-op.
        if (fixedTarget != null) {
          if (folderKey(folder) == folderKey(fixedTarget)) {
            stayed++;
            continue;
          }
          if (await _moveUid(client, uid, fixedTarget)) {
            moved++;
            batch++;
          }
          continue;
        }

        final target = senderFolder(_senderEmail(msg));

        // No usable sender: the INBOX, so nothing is stranded in a folder that
        // is about to be deleted. One agreed starting point for everything the
        // sender cannot place.
        if (target == null) {
          if (await _moveUid(client, uid, 'INBOX')) {
            toInbox++;
            batch++;
          }
          continue;
        }
        if (isFlat && folderKey(target) == ownKey) {
          stayed++;
          continue;
        }
        if (target == folder) {
          stayed++;
          continue;
        }
        if (!known.contains(target)) {
          await _ensureMailbox(client, sk, target, folder);
          known.add(target);
        }
        var ok = await _moveUid(client, uid, target);
        if (!ok) {
          // The target may be gone even though this run believes it exists —
          // a folder the merges deleted is exactly the kind of name the
          // senders now point back at. Create it and try once more rather
          // than counting the mail as stranded.
          await _ensureMailbox(client, sk, target, folder);
          ok = await _moveUid(client, uid, target);
        }
        if (ok) {
          moved++;
          batch++;
        }
      }
      seen += chunk.length;
      if (batch >= 100) {
        try {
          await client.expunge();
        } catch (_) {}
        batch = 0;
      }
      onProgress?.call(OpProgress(
          status: 'running',
          message: '$folder — by sender',
          current: seen,
          total: uids.length));
    }
    try {
      await client.expunge();
    } catch (_) {}

    // Only when the folder is genuinely empty. `stayed > 0` means it is itself
    // the right home for those mails, so it survives the run it was listed in.
    var deleted = false;
    if (deleteSource && stayed == 0 && moved + toInbox == uids.length) {
      try {
        await client.closeMailbox();
      } catch (_) {}
      try {
        await client.deleteMailbox(await _selectPath(client, folder));
        deleted = true;
        _storage.invalidateFolderCache(sk);
      } catch (_) {}
    }
    return ResortResult(
        source: folder,
        total: uids.length,
        moved: moved,
        toInbox: toInbox,
        stayed: stayed,
        sourceDeleted: deleted);
  }

  /// Re-sort many folders over a single connection.
  ///
  /// Same shape as [mergeFolders], for the same reasons: one login for the run,
  /// and [shouldStop] consulted between folders so a cancel lands on a folder
  /// boundary instead of tearing one in half.
  ///
  /// [onSnapshot] is awaited with each folder's Message-IDs before its mails
  /// move. A folder whose record cannot be written is skipped untouched — the
  /// grouping it holds is about to become unreconstructable, and the file is
  /// the only thing that would say what it was.
  ///
  /// **Resumable.** Each folder that comes back without an error is written
  /// down, and a later run skips what is already written. The first run over
  /// this mailbox took five hours; before this, an interruption anywhere in
  /// them started again at the first folder. The foreground service (bug
  /// 15) made that unlikely rather than impossible, and over five hours the
  /// difference matters.
  ///
  /// Only clean folders are recorded, so the ones that failed are tried again
  /// — which is exactly what the second bulk run did by hand, and it cleared
  /// 12 of 13. Recording a folder before its mails move would be the dangerous
  /// way round: an interruption mid-folder would then mark it done, and its
  /// remaining mail would never be looked at again.
  ///
  /// [resume] set to false ignores and clears what was written, for a run that
  /// is meant to go over everything again.
  Future<List<ResortResult>> resortAllFolders(
      AppConfig cfg, String password, List<String> folders,
      {required Future<void> Function(String folder, List<String> ids)
          onSnapshot,
      bool Function()? shouldStop,
      void Function(int done, int total, ResortResult last)? onFolder,
      bool resume = true,
      ProgressCb? onProgress}) async {
    final sk = cfg.serverKey;
    if (!resume) await _storage.clearResortProgress(sk);
    final finished = resume ? _storage.loadResortProgress(sk) : <String>{};
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    final results = <ResortResult>[];
    final known = <String>{};
    // Counts every folder of the run, including the ones skipped as already
    // done, so "N von M" keeps meaning the same thing across a resume.
    var seen = 0;
    try {
      for (final folder in folders) {
        if (shouldStop?.call() ?? false) break;
        seen++;
        if (finished.contains(folder)) continue;
        try {
          final ids = await _collectMessageIds(client, folder,
              onProgress: (p) => onProgress?.call(p));
          await onSnapshot(folder, ids);
        } catch (e) {
          results.add(ResortResult(
              source: folder, total: -1, error: 'not backed up: $e'));
          LongRunGuard.progress('$seen of ${folders.length} folders');
          onFolder?.call(seen, folders.length, results.last);
          continue;
        }
        try {
          results.add(await _resortFolder(client, sk, folder, known,
              onProgress: onProgress));
        } catch (e) {
          results.add(ResortResult(source: folder, total: -1, error: '$e'));
        }
        // Written after the folder is through, never before: a run that dies
        // mid-folder must find it unfinished next time, not marked done.
        if (results.last.error == null) {
          finished.add(folder);
          await _storage.saveResortProgress(sk, finished);
        }
        LongRunGuard.progress('$seen of ${folders.length} folders');
        onFolder?.call(seen, folders.length, results.last);
      }
      // A run that reached the end has nothing left to hand on. Only when it
      // truly reached the end — a stop leaves the record for the next attempt.
      if (!(shouldStop?.call() ?? false)) {
        await _storage.clearResortProgress(sk);
      }
      return results;
    } finally {
      await _logout(client);
    }
  }

  /// The way back: empty every ordinary folder into the INBOX and drop the
  /// folders that are left over.
  ///
  /// The undo for a sort that turned out wrong. It is deliberately not a
  /// delete: a mail moved to the INBOX has lost its filing, not its existence,
  /// and sorting is a pure function of the sender — so running the sort again
  /// reproduces the same tree. That makes this the one bulk operation in the
  /// app whose effect can genuinely be taken back.
  ///
  /// What it must never touch is what makes it safe: [_ordinaryMailboxes]
  /// keeps out the INBOX itself (a move into itself is a copy plus a delete),
  /// All Mail and the other provider views (moving out of All Mail means the
  /// trash), and — since bug 14 — Drafts, Sent, Trash and Spam by name.
  /// Emptying the sent folder into the inbox would be a disaster of its own.
  ///
  /// Same shape as [resortAllFolders]: one login, a Message-ID record written
  /// before a folder is touched, and [shouldStop] read between folders so a
  /// cancel lands on a boundary.
  Future<List<ResortResult>> resetAllToInbox(
      AppConfig cfg, String password, List<String> folders,
      {required Future<void> Function(String folder, List<String> ids)
          onSnapshot,
      bool Function()? shouldStop,
      void Function(int done, int total, ResortResult last)? onFolder,
      ProgressCb? onProgress}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    final results = <ResortResult>[];
    try {
      for (final folder in folders) {
        if (shouldStop?.call() ?? false) break;
        try {
          final ids = await _collectMessageIds(client, folder,
              onProgress: (p) => onProgress?.call(p));
          await onSnapshot(folder, ids);
        } catch (e) {
          results.add(ResortResult(
              source: folder, total: -1, error: 'not backed up: $e'));
          LongRunGuard.progress(
              '${results.length} of ${folders.length} folders');
          onFolder?.call(results.length, folders.length, results.last);
          continue;
        }
        try {
          results.add(await _resortFolder(
              client, cfg.serverKey, folder, <String>{},
              fixedTarget: 'INBOX', onProgress: onProgress));
        } catch (e) {
          results.add(ResortResult(source: folder, total: -1, error: '$e'));
        }
        LongRunGuard.progress('${results.length} of ${folders.length} folders');
        onFolder?.call(results.length, folders.length, results.last);
      }
      return results;
    } finally {
      await _logout(client);
    }
  }

  /// Move every ordinary folder under [parent], so `Amazon` becomes
  /// `parent/Amazon`.
  ///
  /// The reversible half of the last resort: no mail moves and no folder is
  /// destroyed, the tree is just pushed aside so a fresh sort has room. Folders
  /// already under [parent] are left alone, which makes a repeated run a no-op
  /// instead of burying them one level deeper each time.
  Future<int> renameAllFolders(AppConfig cfg, String password, String parent,
      {ProgressCb? onProgress}) async {
    final client = await _connect(cfg, password);
    try {
      final boxes = await _ordinaryMailboxes(client);
      // Deepest first: renaming a parent would otherwise move its children out
      // from under the paths still queued for them.
      boxes.sort((a, b) =>
          b.path.split('/').length.compareTo(a.path.split('/').length));
      var renamed = 0;
      var done = 0;
      for (final box in boxes) {
        if (box.path == parent || box.path.startsWith('$parent/')) continue;
        try {
          // The new name goes over the wire; `renameMailbox` encodes its last
          // segment, the rest is ours. The old name needs nothing — `box` came
          // from LIST and still carries its encoded path.
          await client.renameMailbox(
              box,
              encodeMailboxParents(
                  '$parent/${box.path}', await _pathSeparator(client)));
          renamed++;
        } catch (_) {}
        onProgress?.call(OpProgress(
            status: 'running',
            message: 'Moving to $parent/...',
            current: ++done,
            total: boxes.length));
      }
      _storage.invalidateFolderCache(cfg.serverKey);
      return renamed;
    } finally {
      await _logout(client);
    }
  }

  /// Delete every ordinary folder.
  ///
  /// On Gmail a folder is a label, so this unfiles the mail rather than
  /// destroying it — everything stays reachable in All Mail. On a plain IMAP
  /// server the mails go with the folder. The caller is responsible for making
  /// that distinction clear before calling.
  Future<int> deleteAllFolders(AppConfig cfg, String password,
      {ProgressCb? onProgress}) async {
    final client = await _connect(cfg, password);
    try {
      final boxes = await _ordinaryMailboxes(client);
      boxes.sort((a, b) =>
          b.path.split('/').length.compareTo(a.path.split('/').length));
      var deleted = 0;
      var done = 0;
      for (final box in boxes) {
        try {
          await client.deleteMailbox(box);
          deleted++;
        } catch (_) {}
        onProgress?.call(OpProgress(
            status: 'running',
            message: 'Deleting folders...',
            current: ++done,
            total: boxes.length));
      }
      _storage.invalidateFolderCache(cfg.serverKey);
      return deleted;
    } finally {
      await _logout(client);
    }
  }

  // ── 4. SORT FOLDER ALL — apply rules to every mail in folder ─
  Future<int> sortFolderAll(AppConfig cfg, String password, String folder,
      {ProgressCb? onProgress}) async {
    return _applyRulesToFolder(cfg, password, folder,
        onProgress: onProgress, fixMode: false);
  }

  // ── 5. FIX FOLDER — move misplaced mails (incl. imposters → INBOX) ─
  Future<int> fixFolder(AppConfig cfg, String password, String folder,
      {ProgressCb? onProgress}) async {
    return _applyRulesToFolder(cfg, password, folder,
        onProgress: onProgress, fixMode: true);
  }

  Future<int> _applyRulesToFolder(
      AppConfig cfg, String password, String folder,
      {ProgressCb? onProgress, required bool fixMode}) async {
    onProgress?.call(
        const OpProgress().running(fixMode ? 'Fixing...' : 'Sorting...'));
    final client = await _connect(cfg, password);
    final rules = cfg.activeRules;
    final created = <String>{
      ...(_storage.loadFolderCache(cfg.serverKey)?.map((f) => f.name) ?? [])
    };
    try {
      await _selectPath(client, folder);
      final uids = await _searchAll(client);
      final total = uids.length;
      var moved = 0;
      var current = 0;
      var batch = 0;

      for (final chunk in _chunks(uids, 200)) {
        final seq = MessageSequence.fromIds(chunk, isUid: true);
        final res = await client.uidFetchMessages(seq, _fHeadersSort);
        for (final msg in res.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final faddr = _senderEmail(msg);
          var target = _matchRule(faddr, rules);

          if (fixMode && target == null) {
            // Imposter detection: mails that don't match the folder's own rule.
            final folderRules =
                rules.where((r) => r.moveTo == folder).toList();
            final matchesFolderRule = folderRules.any((r) =>
                r.matchFrom.isNotEmpty &&
                faddr.contains(r.matchFrom.toLowerCase()));
            if (folderRules.isNotEmpty && !matchesFolderRule) {
              target = 'INBOX';
            }
          }

          if (target != null && target.isNotEmpty && target != folder) {
            if (target != 'INBOX' && !created.contains(target)) {
              try {
                await _createPath(client, target);
                _storage.invalidateFolderCache(cfg.serverKey);
              } catch (_) {}
              created.add(target);
              await _selectPath(client, folder);
            }
            if (await _moveUid(client, uid, target)) {
              moved++;
              batch++;
            }
          }
        }
        current += chunk.length;
        if (batch >= 100) {
          try {
            await client.expunge();
          } catch (_) {}
          batch = 0;
        }
        onProgress?.call(OpProgress(
            status: 'running',
            current: current,
            total: total,
            moved: moved,
            message: '${fixMode ? "Fixing" : "Sorting"} '
                '$current/$total ($moved moved)'));
        LongRunGuard.progress('$folder — $current von $total');
      }
      if (batch > 0) {
        try {
          await client.expunge();
        } catch (_) {}
      }
      onProgress?.call(OpProgress(
          status: 'done',
          current: total,
          total: total,
          moved: moved,
          message: 'Done! $moved of $total mails moved.'));
      return moved;
    } finally {
      await _logout(client);
    }
  }

  // ── 6. DELETE DOMAIN FROM FOLDER ──────────────────────────
  Future<int> deleteDomainFromFolder(
      AppConfig cfg, String password, String folder, String domain) async {
    final client = await _connect(cfg, password);
    try {
      await _selectPath(client, folder);
      final uids = await _searchAll(client);
      var deleted = 0;
      final dl = domain.toLowerCase();
      for (final chunk in _chunks(uids, 200)) {
        final seq = MessageSequence.fromIds(chunk, isUid: true);
        final res = await client.uidFetchMessages(seq, _fHeadersFrom);
        final toDelete = <int>[];
        for (final msg in res.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final sd = domainOf(_senderEmail(msg));
          if (sd.contains(dl) || dl.contains(sd)) toDelete.add(uid);
        }
        if (toDelete.isNotEmpty) {
          await client.uidStore(MessageSequence.fromIds(toDelete, isUid: true),
              [MessageFlags.deleted],
              action: StoreAction.add);
          deleted += toDelete.length;
        }
      }
      try {
        await client.expunge();
      } catch (_) {}
      return deleted;
    } finally {
      await _logout(client);
    }
  }

  // ── 10. MOVE DOMAIN TO FOLDER ─────────────────────────────
  Future<int> moveDomainToFolder(AppConfig cfg, String password,
      String sourceFolder, String domain, String targetFolder) async {
    final client = await _connect(cfg, password);
    try {
      try {
        await _createPath(client, targetFolder);
        _storage.invalidateFolderCache(cfg.serverKey);
      } catch (_) {}
      await _selectPath(client, sourceFolder);
      final uids = await _searchAll(client);
      var moved = 0;
      final dl = domain.toLowerCase();
      for (final chunk in _chunks(uids, 200)) {
        final seq = MessageSequence.fromIds(chunk, isUid: true);
        final res = await client.uidFetchMessages(seq, _fHeadersFrom);
        for (final msg in res.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final sd = domainOf(_senderEmail(msg));
          if (sd.contains(dl) || dl.contains(sd)) {
            if (await _moveUid(client, uid, targetFolder)) moved++;
          }
        }
      }
      try {
        await client.expunge();
      } catch (_) {}
      return moved;
    } finally {
      await _logout(client);
    }
  }

  // ── 8. SORT INBOX (resumable) ─────────────────────────────
  Future<int> sortInbox(AppConfig cfg, String password,
      {ProgressCb? onProgress}) async {
    final sk = cfg.serverKey;
    onProgress?.call(const OpProgress().running('Connecting...'));
    final rules = cfg.activeRules;
    final doneUids = _storage.loadProgress(sk);
    // Not seeded from the folder cache: it still lists folders a merge or a
    // by-sender rebuild deleted, and believing it would skip the CREATE and
    // strand every mail heading there. See _resortFolder for the same trap.
    final created = <String>{};
    ImapClient? client;
    var moved = 0;
    try {
      client = await _connect(cfg, password);
      // Says what this run actually goes by. The number here was a hard-wired
      // zero and had always been wrong; in sender mode it was doubly wrong,
      // because no rule is read at all — `rules` is only passed on to
      // `_sortTarget`, which ignores it.
      onProgress?.call(const OpProgress().running(cfg.sortBySender
          ? 'Connected! Sorting by sender.'
          : 'Connected! ${rules.length} rules active.'));
      await client.selectInbox();
      final uids = await _searchAll(client);
      final total = uids.length;
      var current = 0;
      var batch = 0;

      for (final chunk in _chunks(uids, 100)) {
        final pending = chunk.where((u) => !doneUids.contains(u)).toList();
        current += chunk.length;
        if (pending.isEmpty) {
          onProgress?.call(OpProgress(
              status: 'running',
              current: current,
              total: total,
              moved: moved,
              message: '$current/$total ($moved moved)'));
          continue;
        }
        final seq = MessageSequence.fromIds(pending, isUid: true);
        final res = await client.uidFetchMessages(seq, _fHeadersSort);
        for (final msg in res.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final faddr = _senderEmail(msg);
          final target = _sortTarget(cfg, faddr, rules);
          if (target != null && target.isNotEmpty && target != 'INBOX') {
            if (!created.contains(target)) {
              await _ensureMailbox(client, sk, target, 'INBOX');
              created.add(target);
            }
            var ok = await _moveUid(client, uid, target);
            if (!ok) {
              await _ensureMailbox(client, sk, target, 'INBOX');
              ok = await _moveUid(client, uid, target);
            }
            if (ok) moved++;
          }
          doneUids.add(uid);
          batch++;
        }
        if (batch >= 100) {
          try {
            await client.expunge();
          } catch (_) {}
          await _storage.saveProgress(sk, doneUids);
          batch = 0;
        }
        LongRunGuard.progress('$current von $total Mails, $moved moved');
        onProgress?.call(OpProgress(
            status: 'running',
            current: current,
            total: total,
            moved: moved,
            message: '$current/$total ($moved moved)'));
      }
      try {
        await client.expunge();
      } catch (_) {}
      await _storage.clearProgress(sk);
      onProgress?.call(OpProgress(
          status: 'done',
          current: total,
          total: total,
          moved: moved,
          message: 'Done! $moved moved.'));
      return moved;
    } catch (e) {
      await _storage.saveProgress(sk, doneUids);
      onProgress?.call(OpProgress(
          status: 'error',
          moved: moved,
          message: 'Error: ${_clean(e)} — progress saved '
              '(${doneUids.length} UIDs)'));
      rethrow;
    } finally {
      if (client != null) await _logout(client);
    }
  }

  // ── 6b. FIND DUPLICATES ───────────────────────────────────
  Future<DupeResult> findDupes(AppConfig cfg, String password,
      {ProgressCb? onProgress}) async {
    onProgress?.call(const OpProgress().running('Connecting...'));
    final client = await _connect(cfg, password);
    const skip = {
      '[Gmail]/Alle Nachrichten', '[Gmail]/All Mail',
      '[Gmail]/Spam', '[Gmail]/Papierkorb', '[Gmail]/Trash', '[Gmail]/Bin',
      '[Gmail]/Wichtig', '[Gmail]/Important', '[Gmail]/Markiert',
      '[Gmail]/Starred', '[Gmail]/Entwürfe', '[Gmail]/Drafts',
      '[Gmail]/Gesendet', '[Gmail]/Sent Mail',
    };
    try {
      final boxes = await client.listMailboxes(recursive: true);
      final folders = boxes
          .where((b) =>
              !b.isNotSelectable &&
              !_isProviderNamespace(b.path) &&
              !skip.contains(_normalizePath(b.path)))
          .map((b) => b.path)
          .toList();
      onProgress?.call(const OpProgress()
          .running('${folders.length} folders. Scanning...'));

      // Key = Message-ID → entries; fingerprint fallback for missing IDs.
      final msgIdMap = <String, List<Map<String, dynamic>>>{};
      final fingerprintMap = <String, List<Map<String, dynamic>>>{};
      var current = 0;
      var totalMails = 0;

      for (final folder in folders) {
        List<int> uids;
        try {
          await _selectPath(client, folder);
          uids = await _searchAll(client);
        } catch (_) {
          continue;
        }
        totalMails += uids.length;
        for (final chunk in _chunks(uids, 200)) {
          final seq = MessageSequence.fromIds(chunk, isUid: true);
          final res = await client.uidFetchMessages(seq, _fHeadersDupe);
          for (final msg in res.messages) {
            final uid = msg.uid;
            if (uid == null) continue;
            final fr = _fromDisplay(msg).toLowerCase().trim();
            final su = (msg.decodeSubject() ?? '').toLowerCase().trim();
            final dt = (msg.getHeaderValue('date') ?? '').trim();
            final mid = (msg.getHeaderValue('message-id') ?? '').trim();
            final entry = {
              'folder': folder,
              'uid': uid,
              'from': fr.length > 60 ? fr.substring(0, 60) : fr,
              'subject': su.length > 80 ? su.substring(0, 80) : su,
              'date': dt.length > 25 ? dt.substring(0, 25) : dt,
            };
            if (mid.isNotEmpty) {
              (msgIdMap[mid] ??= []).add(entry);
            } else {
              final fp = '$fr|$su|$dt';
              (fingerprintMap[fp] ??= []).add(entry);
            }
          }
          current += chunk.length;
          onProgress?.call(OpProgress(
              status: 'running',
              current: current,
              total: totalMails,
              message: 'Scanning $folder... ($current Mails)'));
        }
      }

      final groups = <DupeGroup>[];
      var totalDupes = 0;

      void addGroup(List<Map<String, dynamic>> entries) {
        groups.add(DupeGroup(
          subject: entries.first['subject'],
          from: entries.first['from'],
          date: entries.first['date'],
          count: entries.length,
          locations: entries
              .map((e) => DupeLocation(folder: e['folder'], uid: e['uid']))
              .toList(),
        ));
        totalDupes += entries.length - 1;
      }

      for (final entries in msgIdMap.values) {
        if (entries.length <= 1) continue;
        final seen = <String>{};
        final real = <Map<String, dynamic>>[];
        for (final e in entries) {
          final key = "${e['folder']}:${e['uid']}";
          if (seen.add(key)) real.add(e);
        }
        if (real.length > 1) addGroup(real);
      }
      for (final entries in fingerprintMap.values) {
        if (entries.length > 1) addGroup(entries);
      }

      groups.sort((a, b) => b.count.compareTo(a.count));
      final unique = msgIdMap.length + fingerprintMap.length;
      onProgress?.call(OpProgress(
          status: 'done',
          current: current,
          total: totalMails,
          message:
              'Done! $unique unique mails, ${groups.length} groups, '
              '$totalDupes copies.'));
      return DupeResult(
        groups: groups.take(200).toList(),
        totalDupes: totalDupes,
        totalGroups: groups.length,
      );
    } finally {
      await _logout(client);
    }
  }

  // ── DELETE DUPLICATES ─────────────────────────────────────
  Future<int> deleteDupes(AppConfig cfg, String password, DupeResult dupes,
      {ProgressCb? onProgress}) async {
    if (dupes.groups.isEmpty) return 0;
    onProgress?.call(const OpProgress().running('Deleting duplicates...'));
    final client = await _connect(cfg, password);
    try {
      final folderDeletes = <String, List<int>>{};
      for (final g in dupes.groups) {
        final inboxLocs =
            g.locations.where((l) => l.folder == 'INBOX').toList();
        final folderLocs =
            g.locations.where((l) => l.folder != 'INBOX').toList();
        List<DupeLocation> toDelete;
        if (folderLocs.isNotEmpty) {
          // Keep first folder copy; delete INBOX copies + remaining folder copies.
          toDelete = [...inboxLocs, ...folderLocs.sublist(1)];
        } else {
          toDelete = inboxLocs.sublist(1);
        }
        for (final loc in toDelete) {
          (folderDeletes[loc.folder] ??= []).add(loc.uid);
        }
      }
      final total = folderDeletes.values.fold<int>(0, (s, l) => s + l.length);
      var deleted = 0;
      for (final entry in folderDeletes.entries) {
        try {
          await _selectPath(client, entry.key);
          await client.uidStore(
              MessageSequence.fromIds(entry.value, isUid: true),
              [MessageFlags.deleted],
              action: StoreAction.add);
          await client.expunge();
          deleted += entry.value.length;
          onProgress?.call(OpProgress(
              status: 'running',
              current: deleted,
              total: total,
              message: 'Deleting $deleted/$total...'));
        } catch (_) {}
      }
      onProgress?.call(OpProgress(
          status: 'done',
          current: deleted,
          total: total,
          message: 'Done! $deleted duplicates deleted.'));
      return deleted;
    } finally {
      await _logout(client);
    }
  }

  // ── 7. SPAM SCAN ──────────────────────────────────────────
  Future<List<SpamEntry>> spamScan(
      AppConfig cfg, String password, String mode,
      {ScanResult? cachedScan, ProgressCb? onProgress}) async {
    await _spam.loadDisposable();
    onProgress?.call(const OpProgress().running('Starting...'));

    // Known domains = rule patterns + folder-name whitelist.
    final knownPatterns = cfg.allRules
        .map((r) => r.matchFrom.toLowerCase())
        .where((p) => p.isNotEmpty)
        .toSet();
    final folderWhitelist = <String>{};
    for (final f in _storage.loadFolderCache(cfg.serverKey, allowStale: true) ??
        []) {
      final part = f.name.split('/').last.toLowerCase().trim();
      if (part.length > 2) folderWhitelist.add(part);
    }
    final known = {...knownPatterns, ...folderWhitelist};

    // sender_data[domain] = {count, subjects[], senders{}, folders{}}
    final senderData = <String, _SenderAgg>{};

    void ingest(MimeMessage msg, String folder) {
      final addr = _senderEmail(msg);
      final domain = domainOf(addr);
      if (domain.length < 4) return;
      final subj = msg.decodeSubject() ?? '';
      final agg = senderData[domain] ??= _SenderAgg();
      agg.count++;
      agg.senders.add(addr);
      agg.folders.add(folder);
      if (agg.subjects.length < 20) agg.subjects.add(subj);
    }

    final client = await _connect(cfg, password);
    try {
      var effectiveMode = mode;

      if (mode == 'smart') {
        final cached = cachedScan ?? ScanResult.empty();
        if (cached.domains.isNotEmpty) {
          // Seed from existing scan (domain + count only).
          for (final d in cached.domains) {
            senderData[d.domain] = _SenderAgg()
              ..count = d.count
              ..senders.add(d.domain);
          }
          // Enrich with subject samples from the last 500 INBOX mails.
          onProgress?.call(const OpProgress()
              .running('Loading subject samples from INBOX...'));
          await client.selectInbox();
          final uids = await _searchAll(client);
          final sample = uids.length > 500
              ? uids.sublist(uids.length - 500)
              : uids;
          var current = 0;
          for (final chunk in _chunks(sample, 100)) {
            final seq = MessageSequence.fromIds(chunk, isUid: true);
            final res = await client.uidFetchMessages(seq, _fHeadersFromSubj);
            for (final msg in res.messages) {
              ingest(msg, 'INBOX');
            }
            current += chunk.length;
            onProgress?.call(OpProgress(
                status: 'running',
                current: current,
                total: sample.length,
                message: 'INBOX samples... $current'));
          }
          return await _scoreCollect(senderData, known, onProgress);
        } else {
          effectiveMode = 'inbox';
        }
      }

      if (effectiveMode == 'inbox') {
        await client.selectInbox();
        final uids = await _searchAll(client);
        final total = uids.length;
        var current = 0;
        for (final chunk in _chunks(uids, 100)) {
          final seq = MessageSequence.fromIds(chunk, isUid: true);
          final res = await client.uidFetchMessages(seq, _fHeadersFromSubj);
          for (final msg in res.messages) {
            ingest(msg, 'INBOX');
          }
          current += chunk.length;
          onProgress?.call(OpProgress(
              status: 'running',
              current: current,
              total: total,
              message: 'INBOX: $current/$total...'));
        }
        return await _scoreCollect(senderData, known, onProgress);
      }

      // FULL mode — all folders.
      const skip = {
        '[Gmail]/Alle Nachrichten', '[Gmail]/All Mail', '[Gmail]/Papierkorb',
        '[Gmail]/Trash', '[Gmail]/Bin', '[Gmail]/Wichtig', '[Gmail]/Important',
        '[Gmail]/Markiert', '[Gmail]/Starred', '[Gmail]/Entwürfe',
        '[Gmail]/Drafts', '[Gmail]/Gesendet', '[Gmail]/Sent Mail',
      };
      final boxes = await client.listMailboxes(recursive: true);
      final folders = <String>[
        'INBOX',
        ...boxes
            .where((b) =>
                !b.isNotSelectable &&
                !_isProviderNamespace(b.path) &&
                !skip.contains(_normalizePath(b.path)) &&
                b.path != 'INBOX')
            .map((b) => b.path),
      ];
      var current = 0;
      for (final folder in folders) {
        try {
          await _selectPath(client, folder);
        } catch (_) {
          continue;
        }
        final uids = await _searchAll(client);
        for (final chunk in _chunks(uids, 100)) {
          final seq = MessageSequence.fromIds(chunk, isUid: true);
          final res = await client.uidFetchMessages(seq, _fHeadersFromSubj);
          for (final msg in res.messages) {
            ingest(msg, folder);
          }
          current += chunk.length;
          onProgress?.call(OpProgress(
              status: 'running',
              current: current,
              total: current,
              message: '$folder: $current mails...'));
        }
      }
      return await _scoreCollect(senderData, known, onProgress);
    } finally {
      await _logout(client);
    }
  }

  Future<List<SpamEntry>> _scoreCollect(
      Map<String, _SenderAgg> data, Set<String> known, ProgressCb? onProgress) async {
    final results = <SpamEntry>[];
    var scored = 0;
    final entries = data.entries.toList();
    // Score in small concurrent batches — each score involves DNSBL lookups.
    for (var i = 0; i < entries.length; i += 20) {
      final batch = entries.sublist(i, i + 20 > entries.length ? entries.length : i + 20);
      await Future.wait(batch.map((e) async {
        final agg = e.value;
        final topSender = agg.senders.isNotEmpty ? agg.senders.first : e.key;
        final (score, reasons) =
            await _spam.spamScore(e.key, topSender, agg.subjects, agg.count, known);
        results.add(SpamEntry(
          domain: e.key,
          count: agg.count,
          score: score,
          reasons: reasons,
          exampleSubject: agg.subjects.isNotEmpty ? agg.subjects.first : '',
          sender: topSender,
          folders: agg.folders.take(3).toList(),
        ));
      }));
      scored += batch.length;
      onProgress?.call(OpProgress(
          status: 'running',
          current: scored,
          total: data.length,
          message: 'Spam check: $scored/${data.length} domains...'));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    onProgress?.call(OpProgress(
        status: 'done',
        message: 'Done! ${results.length} domains analyzed.'));
    return results;
  }

  // ── 11. LIST INBOX (paginated) ────────────────────────────
  Future<InboxPage> listInbox(AppConfig cfg, String password,
      {String folder = 'INBOX', int page = 1, int pageSize = 50}) async {
    final client = await _connect(cfg, password);
    try {
      await _selectPath(client, folder);
      final all = await _searchAll(client);
      final total = all.length;
      final reversed = all.reversed.toList(); // newest first
      final start = (page - 1) * pageSize;
      final pageUids = start >= reversed.length
          ? <int>[]
          : reversed.sublist(
              start,
              (start + pageSize) > reversed.length
                  ? reversed.length
                  : start + pageSize);
      final emails = <InboxEmail>[];
      if (pageUids.isNotEmpty) {
        final seq = MessageSequence.fromIds(pageUids, isUid: true);
        final res = await client.uidFetchMessages(seq, _fInboxList);
        // Preserve requested order (newest first).
        final byUid = {for (final m in res.messages) m.uid: m};
        for (final uid in pageUids) {
          final msg = byUid[uid];
          if (msg == null) continue;
          emails.add(InboxEmail(
            uid: uid,
            fromName: _fromDisplay(msg),
            fromAddr: _senderEmail(msg),
            subject: msg.decodeSubject() ?? '',
            date: msg.getHeaderValue('date') ?? '',
            seen: msg.isSeen,
          ));
        }
      }
      return InboxPage(
        emails: emails,
        total: total,
        page: page,
        pages: total == 0 ? 1 : ((total + pageSize - 1) ~/ pageSize),
      );
    } finally {
      await _logout(client);
    }
  }

  // ── 11. READ EMAIL ────────────────────────────────────────
  /// Replace `cid:...` image sources with data-URIs from the embedded
  /// attachments — without this, signatures and logos in corporate mails
  /// remain empty placeholders because the image can never be loaded from
  /// the network: it lives entirely inside the mail attachment.
  String _inlineCidImages(MimeMessage msg, String html) {
    if (html.isEmpty || !html.contains('cid:')) return html;
    final cidPattern = RegExp(
      '''cid:([^"'>\\s]+)''',
      caseSensitive: false,
    );
    var result = html;
    final seen = <String>{};
    for (final match in cidPattern.allMatches(html)) {
      final rawCid = match.group(1)!;
      if (!seen.add(rawCid)) continue;
      try {
        final part = msg.getPartWithContentId(rawCid) ??
            msg.getPartWithContentId('<$rawCid>');
        if (part == null) continue;
        final bytes = part.decodeContentBinary();
        if (bytes == null || bytes.isEmpty) continue;
        // Over 3 MB is no longer a signature logo but a photo —
        // embedding it as a base64 data-URI costs more memory than
        // the crash it caused earlier was worth.
        if (bytes.length > 3 * 1024 * 1024) continue;
        final mediaType =
            part.getHeaderContentType()?.mediaType.text ?? 'image/png';
        final dataUri = 'data:$mediaType;base64,${base64Encode(bytes)}';
        result = result.replaceAll('cid:$rawCid', dataUri);
      } catch (_) {
        // A single broken inline image should not make the whole mail
        // unreadable — just leave it as a placeholder.
      }
    }
    return result;
  }

  Future<EmailContent> readEmail(
      AppConfig cfg, String password, String folder, int uid) async {
    final client = await _connect(cfg, password);
    try {
      await _selectPath(client, folder);
      final seq = MessageSequence.fromIds([uid], isUid: true);
      final res = await client.uidFetchMessages(seq, _fFull);
      if (res.messages.isEmpty) throw ImapFailure('Mail not found.');
      final msg = res.messages.first;
      // Mark as read.
      try {
        await client.uidMarkSeen(seq);
      } catch (_) {}

      final text = msg.decodeTextPlainPart() ?? '';
      // Truncate *before* CID-inlining — otherwise the cut can land in
      // the middle of an embedded base64 image URI. A broken data:-image
      // crashed flutter_html during decoding instead of just looking ugly.
      final rawHtml = msg.decodeTextHtmlPart() ?? '';
      final truncatedHtml =
          rawHtml.length > 100000 ? rawHtml.substring(0, 100000) : rawHtml;
      final html = _inlineCidImages(msg, truncatedHtml);
      final attachments = <EmailAttachment>[];
      try {
        for (final ci in msg.findContentInfo()) {
          attachments.add(EmailAttachment(
            name: ci.fileName ?? 'attachment',
            type: ci.mediaType?.text ?? '',
            size: ci.size ?? 0,
          ));
        }
      } catch (_) {}

      return EmailContent(
        uid: uid,
        from: _fromRaw(msg),
        to: msg.to?.map((a) => a.toString()).join(', ') ?? '',
        subject: msg.decodeSubject() ?? '',
        date: msg.getHeaderValue('date') ?? '',
        textBody: text.length > 50000 ? text.substring(0, 50000) : text,
        htmlBody: html,
        attachments: attachments,
      );
    } finally {
      await _logout(client);
    }
  }

  String _fromRaw(MimeMessage msg) {
    final from = msg.from;
    if (from != null && from.isNotEmpty) {
      return from.map((a) => a.toString()).join(', ');
    }
    return msg.getHeaderValue('from') ?? '';
  }

  // ── 12. MARK ALL READ ─────────────────────────────────────
  Future<int> markAllRead(AppConfig cfg, String password,
      {String folder = 'INBOX'}) async {
    final client = await _connect(cfg, password);
    try {
      await _selectPath(client, folder);
      final res = await client.uidSearchMessages(searchCriteria: 'UNSEEN');
      final uids = res.matchingSequence?.toList() ?? const [];
      if (uids.isEmpty) return 0;
      await client.uidMarkSeen(MessageSequence.fromIds(uids, isUid: true));
      return uids.length;
    } finally {
      await _logout(client);
    }
  }
}

/// Aggregation bucket for the spam scan.
class _SenderAgg {
  int count = 0;
  final List<String> subjects = [];
  final Set<String> senders = {};
  final Set<String> folders = {};
}
