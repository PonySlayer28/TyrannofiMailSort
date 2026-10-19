// Domain helpers ported 1:1 from gmail_app.py.

const Set<String> _subdomainSkip = {
  'mail', 'email', 'e', 'm', 'news', 'newsletter', 'info', 'marketing',
  'reply', 'notifications', 'update', 'my', 'n', 'eg', 'crm', 'von',
  'service', 'mailer', 'post', 'ses', 'cmp', 'notify', 'comms', 'mailout',
};

/// Country suffixes that are two labels long, so the name sits one label
/// further left: in `amazon.co.uk` the last two parts are `co.uk`, which names
/// no one. Taking them anyway filed every British, Australian and Japanese
/// sender into a single folder called `Co`.
///
/// A short list rather than the full public suffix list: that one runs to
/// thousands of entries and needs updating, while these cover the senders a
/// German mailbox actually sees. A suffix that is missing costs one oddly
/// named folder, not a lost mail.
const Set<String> _twoPartSuffixes = {
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'me.uk', 'net.uk', 'sch.uk',
  'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au', 'id.au',
  'co.jp', 'or.jp', 'ne.jp', 'ac.jp', 'go.jp',
  'co.nz', 'net.nz', 'org.nz', 'ac.nz',
  'com.br', 'net.br', 'org.br',
  'co.za', 'org.za', 'co.il', 'org.il', 'co.in', 'net.in', 'org.in',
  'co.kr', 'or.kr', 'com.mx', 'com.ar', 'com.tr', 'com.cn', 'com.hk',
  'com.sg', 'com.my', 'com.tw', 'com.ua', 'com.pl', 'com.ru',
};

/// Reduce a full sender domain to its "base" (e.g. `mail.news.paypal.de`
/// → `paypal.de`) by stripping known subdomain prefixes.
String extractBaseDomain(String domain) {
  var parts = domain.split('.');
  while (parts.length > 2 && _subdomainSkip.contains(parts.first)) {
    parts = parts.sublist(1);
  }
  // One label further left when the tail is a two-part country suffix, so
  // `amazon.co.uk` keeps `amazon` instead of collapsing to `co`.
  final keep =
      parts.length > 2 && _twoPartSuffixes.contains(parts.sublist(parts.length - 2).join('.'))
          ? 3
          : 2;
  if (parts.length >= keep) {
    return parts.sublist(parts.length - keep).join('.');
  }
  return domain;
}

/// Suggest a folder name for a domain (e.g. `paypal.de` → `Paypal`).
String domainToFolder(String domain) {
  final name = domain.contains('.') ? domain.split('.').first : domain;
  if (name.isEmpty) return domain;
  return name[0].toUpperCase() + name.substring(1);
}

/// Extract the sender's domain from an email address (part after the last `@`).
String domainOf(String address) {
  final a = address.toLowerCase();
  final at = a.lastIndexOf('@');
  return at >= 0 ? a.substring(at + 1) : a;
}

/// Mailbox names that carry the user's own mail flow rather than filed mail:
/// drafts, sent, trash, spam, outbox. Never a source for sorting and never a
/// target — sorting drafts by their sender would scatter unsent mail into
/// stranger's folders, and a bulk delete would take them with it.
///
/// Servers usually flag these `\Drafts`, `\Sent` and so on, and that flag is
/// checked first. This list is the second net: not every server sets the flag,
/// and leftovers from an old migration often sit unmarked at the top level.
/// A plain `Entwürfe` (German "Drafts") once slipped past the flag check into
/// a by-sender run — only a command error stopped it from emptying the drafts.
const Set<String> _reservedMailboxNames = {
  'trash', 'papierkorb', 'bin', 'deleted items', 'deleted messages',
  'sent', 'gesendet', 'sent items', 'sent messages', 'sent mail',
  'drafts', 'entwürfe', 'entwuerfe',
  'junk', 'junk e-mail', 'spam',
  'archive', 'archiv',
  'outbox', 'postausgang',
};

/// Does [path] name a mailbox that must never be sorted, renamed or deleted?
///
/// Checks the whole path and its last segment, so both `Entwürfe` and
/// `Alt/Entwürfe` are caught. A folder wrongly skipped merely stays as it is;
/// one wrongly touched loses mail that was never filed anywhere.
bool isReservedMailboxName(String path) {
  final p = path.toLowerCase().trim();
  return _reservedMailboxNames.contains(p) ||
      _reservedMailboxNames.contains(p.split('/').last.trim());
}

/// Mailboxes no bulk operation may ever use as a source or a target, decided
/// from the path alone.
///
/// Three separate reasons, all of which end the same way:
/// - **INBOX** — moving a mail into the box it already sits in is a copy plus a
///   delete of the original, not a no-op.
/// - **`[…]` namespaces** — `[Gmail]/Alle Nachrichten` and its siblings. A move
///   *out of* All Mail is not a label change but a trip to the trash.
/// - **Reserved names** — drafts, sent, trash, spam. Emptying the sent folder
///   into the inbox would be its own disaster.
///
/// The server's special-use flag is checked separately and first; this is the
/// net for the servers that do not set it. Pure, so the promise can be tested
/// rather than trusted.
bool isProtectedMailboxPath(String path) {
  final p = path.trim();
  return p.toUpperCase() == 'INBOX' ||
      p.startsWith('[') ||
      isReservedMailboxName(p);
}

/// Strip everything an IMAP path would read as structure or a server would
/// reject. A From header is data written by a stranger: without this a sender
/// domain spelled `a/b.de` would quietly create a subfolder, and one with a
/// `*` or a control character would break the command it is pasted into.
/// Letters stay as they are, so an umlaut domain keeps its umlaut.
String safeFolderSegment(String name) =>
    name.replaceAll(RegExp(r'[/\\\x00-\x1f"%*\x7f]'), '').trim();

/// The folder a mail belongs in when sorting strictly by sender: one flat
/// folder per sender domain, no categories. `service@mail.amazon.de` → `Amazon`.
///
/// Returns null when the address yields no usable domain — a malformed or
/// missing From header. Such a mail has no derivable place, and the caller
/// sends it to the INBOX rather than leaving it behind in a folder that is
/// about to be removed.
String? senderFolder(String address) {
  final domain = extractBaseDomain(domainOf(address));
  if (!domain.contains('.')) return null;
  final name = safeFolderSegment(domainToFolder(domain));
  return name.isEmpty ? null : name;
}

/// Comparison key for a folder's own name, ignoring case and separators, so
/// `Native-instruments` and `NativeInstruments` are recognised as the same
/// thing. Pass a single path segment, not a whole path.
String folderKey(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Split on everything that is not a letter or digit: `mail.bike-discount.de`
/// → `[mail, bike, discount, de]`.
List<String> domainTokens(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((t) => t.isNotEmpty)
    .toList();

/// Does [pattern] name [domain]?
///
/// Compares whole dot- and dash-separated parts rather than raw substrings.
/// Plain `contains` made every rule a trap for its neighbours: `auto` (from a
/// folder named `Tech/Auto`) swallowed `meinauto.de`, `autodoc.de` and
/// `atp-autoteile.de`, and `steam` swallowed `cbs-team.de`. Parts must match
/// consecutively, so `paypal` still finds `mail.paypal.de` and the full
/// `paypal.de` still finds it too.
bool patternMatchesDomain(String pattern, String domain) {
  final p = domainTokens(pattern);
  final d = domainTokens(domain);
  if (p.isEmpty || d.isEmpty || p.length > d.length) return false;
  for (var i = 0; i + p.length <= d.length; i++) {
    var hit = true;
    for (var j = 0; j < p.length; j++) {
      if (d[i + j] != p[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// Does [pattern] name the sender behind [address]? Matches the domain, not the
/// local part — a rule for `paypal` should not fire on `paypal@gmail.com`.
bool patternMatchesSender(String pattern, String address) =>
    patternMatchesDomain(pattern, domainOf(address));
