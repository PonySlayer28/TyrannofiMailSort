// Result & progress models for all IMAP operations.
// These mirror the JSON structures returned by gmail_app.py.

/// Live progress for long-running operations (scan, sort, dupes, spam …).
class OpProgress {
  final String status; // idle | running | done | error
  final int current;
  final int total;
  final int moved;
  final String message;

  const OpProgress({
    this.status = 'idle',
    this.current = 0,
    this.total = 0,
    this.moved = 0,
    this.message = '',
  });

  const OpProgress.idle() : this();

  OpProgress running(String message, {int? current, int? total, int? moved}) =>
      OpProgress(
        status: 'running',
        current: current ?? this.current,
        total: total ?? this.total,
        moved: moved ?? this.moved,
        message: message,
      );

  double get fraction => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
  bool get isRunning => status == 'running';
  bool get isError => status == 'error';
  bool get isDone => status == 'done';
}

/// One domain group from an inbox scan.
class DomainScanEntry {
  final String domain;
  final int count;
  final List<String> senders;
  final List<String> examples;

  DomainScanEntry({
    required this.domain,
    required this.count,
    this.senders = const [],
    this.examples = const [],
  });

  Map<String, dynamic> toJson() => {
        'domain': domain,
        'count': count,
        'senders': senders,
        'examples': examples,
      };

  factory DomainScanEntry.fromJson(Map j) => DomainScanEntry(
        domain: j['domain'] ?? '',
        count: j['count'] ?? 0,
        senders: (j['senders'] as List?)?.map((e) => e.toString()).toList() ?? [],
        examples:
            (j['examples'] as List?)?.map((e) => e.toString()).toList() ?? [],
      );
}

class ScanResult {
  final List<DomainScanEntry> domains;
  final int total;
  final int analyzed;

  ScanResult({required this.domains, required this.total, required this.analyzed});

  Map<String, dynamic> toJson() => {
        'domains': domains.map((d) => d.toJson()).toList(),
        'total': total,
        'analyzed': analyzed,
      };

  factory ScanResult.fromJson(Map j) => ScanResult(
        domains: (j['domains'] as List?)
                ?.map((e) => DomainScanEntry.fromJson(e as Map))
                .toList() ??
            [],
        total: j['total'] ?? 0,
        analyzed: j['analyzed'] ?? 0,
      );

  factory ScanResult.empty() => ScanResult(domains: [], total: 0, analyzed: 0);
}

class FolderInfo {
  final String name;
  final int count;

  FolderInfo({required this.name, required this.count});

  Map<String, dynamic> toJson() => {'name': name, 'count': count};
  factory FolderInfo.fromJson(Map j) =>
      FolderInfo(name: j['name'] ?? '', count: j['count'] ?? 0);
}

/// One domain group inside a folder scan.
class FolderDomainEntry {
  final String domain;
  final int count;
  final int wrongCount;
  final String shouldBe;
  final List<String> examples;

  FolderDomainEntry({
    required this.domain,
    required this.count,
    required this.wrongCount,
    required this.shouldBe,
    this.examples = const [],
  });
}

class FolderScanResult {
  final String folder;
  final List<FolderDomainEntry> domains;
  final int total;
  final int wrong;

  FolderScanResult({
    required this.folder,
    required this.domains,
    required this.total,
    required this.wrong,
  });
}

class DupeLocation {
  final String folder;
  final int uid;
  DupeLocation({required this.folder, required this.uid});
}

class DupeGroup {
  final String subject;
  final String from;
  final String date;
  final int count;
  final List<DupeLocation> locations;

  DupeGroup({
    required this.subject,
    required this.from,
    required this.date,
    required this.count,
    required this.locations,
  });
}

class DupeResult {
  final List<DupeGroup> groups;
  final int totalDupes;
  final int totalGroups;

  DupeResult({
    required this.groups,
    required this.totalDupes,
    required this.totalGroups,
  });

  factory DupeResult.empty() =>
      DupeResult(groups: [], totalDupes: 0, totalGroups: 0);
}

class SpamEntry {
  final String domain;
  final int count;
  final int score;
  final List<String> reasons;
  final String exampleSubject;
  final String sender;
  final List<String> folders;

  SpamEntry({
    required this.domain,
    required this.count,
    required this.score,
    required this.reasons,
    required this.exampleSubject,
    required this.sender,
    required this.folders,
  });
}

class InboxEmail {
  final int uid;
  final String fromName;
  final String fromAddr;
  final String subject;
  final String date;
  final bool seen;

  InboxEmail({
    required this.uid,
    required this.fromName,
    required this.fromAddr,
    required this.subject,
    required this.date,
    required this.seen,
  });
}

class InboxPage {
  final List<InboxEmail> emails;
  final int total;
  final int page;
  final int pages;

  InboxPage({
    required this.emails,
    required this.total,
    required this.page,
    required this.pages,
  });
}

class EmailAttachment {
  final String name;
  final String type;
  final int size;
  EmailAttachment({required this.name, required this.type, required this.size});
}

class EmailContent {
  final int uid;
  final String from;
  final String to;
  final String subject;
  final String date;
  final String textBody;
  final String htmlBody;
  final List<EmailAttachment> attachments;

  EmailContent({
    required this.uid,
    required this.from,
    required this.to,
    required this.subject,
    required this.date,
    required this.textBody,
    required this.htmlBody,
    required this.attachments,
  });
}

/// Two folders that mean the same thing: a flat one the app generated from a
/// sender domain, and the hierarchical one sorted by hand. [target] is always
/// the hierarchical one — it carries the categorisation the flat name lacks.
class FolderMergePair {
  final String source;
  final String target;
  final int sourceCount;
  final int targetCount;

  const FolderMergePair({
    required this.source,
    required this.target,
    required this.sourceCount,
    required this.targetCount,
  });
}

class MergeResult {
  final String source;
  final String target;
  final int moved;
  final int total;
  final bool sourceDeleted;

  const MergeResult({
    required this.source,
    required this.target,
    required this.moved,
    required this.total,
    required this.sourceDeleted,
  });

  bool get complete => moved == total;
}

/// What re-sorting one folder by sender did.
///
/// The four counts are exhaustive: every mail the folder held either moved to
/// its sender's folder, went to the INBOX for want of a usable sender, was
/// already in the right place, or failed to move. They are reported separately
/// because they mean different things — mails in the INBOX are work waiting,
/// mails that stayed are proof the folder was already correct, and a failure
/// is the reason the folder is still there.
class ResortResult {
  final String source;
  final int total;
  final int moved;
  final int toInbox;
  final int stayed;
  final bool sourceDeleted;

  /// Set when the folder was skipped entirely — no mail was touched.
  final String? error;

  const ResortResult({
    required this.source,
    required this.total,
    this.moved = 0,
    this.toInbox = 0,
    this.stayed = 0,
    this.sourceDeleted = false,
    this.error,
  });

  int get handled => moved + toInbox + stayed;

  /// Every mail accounted for. Not the same as [sourceDeleted]: a folder that
  /// was already correct is complete and still stands.
  bool get complete => error == null && handled == total;

  int get failed => error == null ? total - handled : 0;
}

/// One written backup: which folder it records, how many mails, and when.
class BackupFile {
  final String path;
  final String folder;
  final int count;
  final DateTime? savedAt;

  const BackupFile({
    required this.path,
    required this.folder,
    required this.count,
    required this.savedAt,
  });
}

/// Thrown by IMAP operations so the UI can show a clean message.
class ImapFailure implements Exception {
  final String message;
  ImapFailure(this.message);
  @override
  String toString() => message;
}
