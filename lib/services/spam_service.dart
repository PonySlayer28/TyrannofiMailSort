import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'storage_service.dart';

/// Spam scoring + disposable-domain / blacklist databases,
/// ported from the SPAM section of gmail_app.py.
class SpamService {
  SpamService._();
  static final SpamService instance = SpamService._();

  final _storage = StorageService.instance;

  // DNSBL zones checked in parallel, mirroring DNSBL_DOMAIN_LISTS in gmail_app.py.
  static const _dnsblLists = [
    ('dbl.spamhaus.org', 'Spamhaus DBL', 50),
    ('multi.surbl.org', 'SURBL', 40),
    ('dnsbl.abuse.ch', 'abuse.ch', 40),
  ];

  final Map<String, List<(String, int)>> _dnsblCache = {};

  /// Check a domain against all DNS blacklists in parallel.
  /// A zone resolving (instead of NXDOMAIN) means the domain is listed.
  Future<List<(String, int)>> checkDnsbl(String domain) async {
    final d = domain.toLowerCase().trim();
    final cached = _dnsblCache[d];
    if (cached != null) return cached;

    final hits = <(String, int)>[];
    await Future.wait(_dnsblLists.map((entry) async {
      final (zone, name, pts) = entry;
      try {
        final result = await InternetAddress.lookup('$d.$zone')
            .timeout(const Duration(seconds: 4));
        if (result.isNotEmpty) hits.add((name, pts));
      } catch (_) {
        // NXDOMAIN / timeout / no network → not listed (or unknown).
      }
    }));

    _dnsblCache[d] = hits;
    return hits;
  }

  static const _disposableUrl =
      'https://raw.githubusercontent.com/disposable/disposable-email-domains/master/domains.txt';
  static const _ttlSeconds = 86400; // 24h

  Set<String> _disposable = {};
  bool _loaded = false;
  String dbStatus = 'not loaded';
  int dbCount = 0;
  int? lastUpdate;

  static const spamKeywords = [
    // German
    'gewinner', 'gewonnen', 'gewinnen', 'gratis', 'kostenlos', 'sonderangebot',
    'rabatt', 'jetzt kaufen', 'dringend', 'achtung', 'wichtig', 'verifizier',
    'konto gesperrt', 'passwort', 'bestätigen sie', 'klicken sie hier',
    'nur noch heute', 'limitiert', 'exklusiv', 'millionen', 'erbschaft',
    'lotteri', 'jackpot', 'preisträger', 'überweisen', 'zahlung',
    // English
    'winner', 'won', 'free', 'offer', 'discount', 'click here', 'unsubscribe',
    'limited time', 'act now', 'urgent', 'verify', 'account suspended',
    'confirm your', 'congratulations', 'million', 'inheritance', 'lottery',
    'prize', 'transfer', 'payment required', 'dear friend', 'nigerian',
    'bulk', 'marketing', 'newsletter unsubscribe', 'opt-out',
  ];

  static const spamDomainPatterns = [
    'bulk', 'mass', 'promo', 'marketing', 'noreply', 'no-reply', 'mailer',
    'newsletter', 'notifications', 'bounce', 'campaign', 'sendgrid',
    'mailchimp', 'constantcontact', 'exacttarget', 'responsys', 'klaviyo',
  ];

  /// Load disposable domains from cache or download from GitHub.
  Future<bool> loadDisposable({bool force = false}) async {
    if (!force) {
      final cached = _storage.disposableDomains;
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 -
          _storage.disposableTs;
      if (cached.isNotEmpty && age < _ttlSeconds) {
        _disposable = cached;
        _loaded = true;
        dbCount = cached.length;
        lastUpdate = _storage.disposableTs;
        dbStatus = 'ok';
        return true;
      }
    }
    try {
      final resp = await http.get(
        Uri.parse(_disposableUrl),
        headers: {'User-Agent': 'TyrannoFi/1.0'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final lines = resp.body
          .split('\n')
          .map((l) => l.trim().toLowerCase())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toSet();
      _disposable = lines;
      _loaded = true;
      dbCount = lines.length;
      dbStatus = 'ok';
      lastUpdate = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _storage.saveDisposable(lines);
      return true;
    } catch (e) {
      // Fall back to any stale cache.
      final cached = _storage.disposableDomains;
      if (cached.isNotEmpty) {
        _disposable = cached;
        _loaded = true;
        dbCount = cached.length;
        dbStatus = 'stale (offline)';
        return false;
      }
      dbStatus = 'Error: $e';
      return false;
    }
  }

  bool isDisposable(String domain) => _disposable.contains(domain.toLowerCase());

  /// (isListed, matchedEntry) — checks domain + sender against custom blacklist.
  (bool, String) inCustomBlacklist(String domain, String sender) {
    final bl = _storage.loadBlacklist();
    final d = domain.toLowerCase();
    final s = sender.toLowerCase();
    if (bl.containsKey(d)) return (true, d);
    if (bl.containsKey(s)) return (true, s);
    for (final e in bl.entries) {
      if (e.value['type'] == 'domain' &&
          (d.endsWith(e.key) || e.key.endsWith(d))) {
        return (true, e.key);
      }
    }
    return (false, '');
  }

  /// Compute spam score 0-100 with reasons for a sender/domain.
  Future<(int, List<String>)> spamScore(
    String domain,
    String sender,
    List<String> subjects,
    int count,
    Set<String> knownDomains,
  ) async {
    var score = 0;
    final reasons = <String>[];

    if (!knownDomains.contains(domain)) {
      score += 30;
      reasons.add('Unknown domain');
    }

    final dLower = domain.toLowerCase();
    for (final pat in spamDomainPatterns) {
      if (dLower.contains(pat)) {
        score += 15;
        reasons.add('Suspicious domain name ($pat)');
        break;
      }
    }

    if (count > 20 && !knownDomains.contains(domain)) {
      score += 15;
      reasons.add('Many mails without a rule (${count}x)');
    } else if (count > 50 && !knownDomains.contains(domain)) {
      score += 10;
    }

    if (count == 1) {
      score += 5;
      reasons.add('One-time sender');
    }

    final kwHits = <String>[];
    for (final subj in subjects.take(20)) {
      final sl = subj.toLowerCase();
      for (final kw in spamKeywords) {
        if (sl.contains(kw) && !kwHits.contains(kw)) {
          kwHits.add(kw);
          score += 12;
          break;
        }
      }
    }
    if (kwHits.isNotEmpty) {
      reasons.add('Spam keywords in subject: ${kwHits.take(3).join(', ')}');
    }

    final local = sender.contains('@') ? sender.split('@').first : sender;
    final digitCount = local.split('').where((c) => '0123456789'.contains(c)).length;
    if (local.length > 20 || digitCount > 6) {
      score += 10;
      reasons.add('Suspicious sender address');
    }

    if (isDisposable(domain)) {
      score += 40;
      reasons.add('⚠ Disposable/spam domain (database)');
    }

    final (inBl, blEntry) = inCustomBlacklist(domain, sender);
    if (inBl) {
      score += 60;
      reasons.add('🔒 Custom blacklist ($blEntry)');
    }

    for (final (blName, pts) in await checkDnsbl(domain)) {
      score += pts;
      reasons.add('🚨 Listed in $blName');
    }

    return (score > 100 ? 100 : score, reasons);
  }

  bool get isLoaded => _loaded;
}
