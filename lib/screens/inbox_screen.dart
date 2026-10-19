import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_html_table/flutter_html_table.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models/results.dart';
import '../services/imap_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

class InboxScreen extends StatefulWidget {
  final String folder;
  const InboxScreen({super.key, this.folder = 'INBOX'});
  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;

  InboxPage? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  Future<void> _load(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _imap.listInbox(_app.config, _app.password,
          folder: widget.folder, page: page);
      setState(() {
        _page = p;
        _pageNum = page;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead() async {
    try {
      final n =
          await _imap.markAllRead(_app.config, _app.password, folder: widget.folder);
      if (mounted) showSnack(context, '$n emails marked as read.');
      _load(_pageNum);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _open(InboxEmail e) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => EmailScreen(folder: widget.folder, email: e)),
    );
    _load(_pageNum);
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Scaffold(
      appBar: tfAppBar(
        widget.folder.toUpperCase(),
        actions: [
          IconButton(
            icon: const Icon(Icons.mark_email_read_outlined),
            tooltip: 'Mark all as read',
            onPressed: _markAllRead,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(_pageNum),
          ),
        ],
      ),
      body: _loading && _page == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? EmptyState(icon: Icons.error_outline, message: _error!)
              : p == null || p.emails.isEmpty
                  ? const EmptyState(
                      icon: Icons.inbox, message: 'No emails.')
                  : Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: p.emails.length,
                            itemBuilder: (_, i) => _emailTile(p.emails[i]),
                          ),
                        ),
                        _pager(p),
                      ],
                    ),
    );
  }

  Widget _emailTile(InboxEmail e) {
    return Card(
      child: ListTile(
        leading: Icon(e.seen ? Icons.drafts_outlined : Icons.mark_email_unread,
            color: e.seen ? TF.text2 : TF.accent),
        title: Text(e.fromName.isEmpty ? e.fromAddr : e.fromName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13,
                fontWeight: e.seen ? FontWeight.w400 : FontWeight.w700,
                color: e.seen ? TF.text2 : TF.text)),
        subtitle: Text(e.subject.isEmpty ? '(no subject)' : e.subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: TF.text2, fontSize: 12)),
        onTap: () => _open(e),
      ),
    );
  }

  Widget _pager(InboxPage p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: TF.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed:
                (_loading || _pageNum <= 1) ? null : () => _load(_pageNum - 1),
          ),
          Text('Page ${p.page} / ${p.pages}  ·  ${p.total} emails',
              style: const TextStyle(color: TF.text2, fontSize: 12)),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: (_loading || _pageNum >= p.pages)
                ? null
                : () => _load(_pageNum + 1),
          ),
        ],
      ),
    );
  }
}

class EmailScreen extends StatefulWidget {
  final String folder;
  final InboxEmail email;
  const EmailScreen({super.key, required this.folder, required this.email});
  @override
  State<EmailScreen> createState() => _EmailScreenState();
}

class _EmailScreenState extends State<EmailScreen> {
  final _app = AppState.instance;
  final _imap = ImapService.instance;
  EmailContent? _content;
  String? _error;

  /// Tap recognizers for links in text view — must be disposed with the state.
  final _linkRecognizers = <TapGestureRecognizer>[];

  /// Shows HTML view instead of text view.
  bool _html = false;

  /// Images are loaded only after an explicit tap — otherwise every opened
  /// mail confirms to the sender via tracking pixel that it was read.
  bool _loadImages = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await _imap.readEmail(
          _app.config, _app.password, widget.folder, widget.email.uid);
      setState(() {
        _content = c;
        // Text view is preferred because it always shows something. HTML of
        // some newsletters renders to a blank page in flutter_html; text is
        // always readable. Start with HTML only when there is no text.
        _html = c.textBody.trim().isEmpty;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _content;
    final bothForms =
        c != null && c.textBody.trim().isNotEmpty && c.htmlBody.isNotEmpty;
    return Scaffold(
      appBar: tfAppBar('MAIL', actions: [
        if (_html && c != null && c.htmlBody.isNotEmpty)
          IconButton(
            icon: Icon(_loadImages ? Icons.image : Icons.image_not_supported),
            tooltip: _loadImages ? 'Block images' : 'Load images',
            onPressed: () => setState(() => _loadImages = !_loadImages),
          ),
        if (bothForms)
          IconButton(
            icon: Icon(_html ? Icons.subject : Icons.code),
            tooltip: _html ? 'As text' : 'As HTML',
            onPressed: () => setState(() => _html = !_html),
          ),
      ]),
      body: _error != null
          ? EmptyState(icon: Icons.error_outline, message: _error!)
          : c == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(c.subject.isEmpty ? '(no subject)' : c.subject,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: TF.accent2)),
                    const SizedBox(height: 10),
                    _meta('From', c.from),
                    if (c.to.isNotEmpty) _meta('To', c.to),
                    if (c.date.isNotEmpty) _meta('Date', c.date),
                    if (c.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: c.attachments
                              .map((a) => Chip(
                                    avatar: const Icon(Icons.attach_file,
                                        size: 14, color: TF.accent),
                                    label: Text(a.name,
                                        style: const TextStyle(fontSize: 11)),
                                  ))
                              .toList(),
                        ),
                      ),
                    const Divider(height: 28),
                    _body(c),
                  ],
                ),
    );
  }

  /// The mail body in the selected format.
  ///
  /// `<table>` needs [TableHtmlExtension] in flutter_html 3 — without it,
  /// table layouts are entirely blank. Even with it, some heavily table-based
  /// mails (e.g. old PlayStation newsletters) don't render readably.
  /// Removes `<img>` tags entirely instead of just hiding them — flutter_html
  /// would still load the source in the background, which is exactly what
  /// tracking pixels exploit.
  String _withoutImages(String html) =>
      html.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '');

  Widget _body(EmailContent c) {
    if (_html && c.htmlBody.isNotEmpty) {
      return Html(
        data: _loadImages ? c.htmlBody : _withoutImages(c.htmlBody),
        extensions: const [TableHtmlExtension()],
        style: {
          'body': Style(
            color: TF.text,
            fontSize: FontSize(14),
            lineHeight: const LineHeight(1.5),
            margin: Margins.zero,
            backgroundColor: Colors.transparent,
          ),
          'a': Style(color: TF.accent),
        },
        onLinkTap: (url, _, __) {
          if (url == null) return;
          final uri = Uri.tryParse(url);
          if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
        },
      );
    }
    final text = _cleanText(c.textBody);
    if (text.isEmpty) {
      return const SelectableText(
        '(No text content)',
        style: TextStyle(color: TF.text, fontSize: 14, height: 1.5),
      );
    }
    return SelectableText.rich(
      TextSpan(children: _linkifiedSpans(text)),
      style: const TextStyle(color: TF.text, fontSize: 14, height: 1.5),
    );
  }

  // Also catches "www." links without a scheme — senders often write links
  // in plain-text mails without "https://", but they are still links.
  static final _urlPattern = RegExp(
    r'((?:https?://|www\.)[^\s<>"]+)',
    caseSensitive: false,
  );

  // Punctuation that belongs to the surrounding sentence, not the URL.
  static final _trailingPunctuation = RegExp(r'''[.,;:!?)\]}>'"]+$''');

  /// Splits plain text line by line: quoted lines (">...") are dimmed/italic
  /// so new content and reply chains are visually distinct. Links are detected
  /// in every line regardless of quoting.
  List<InlineSpan> _linkifiedSpans(String text) {
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isQuoted = line.trimLeft().startsWith('>');
      spans.addAll(_linkifiedLine(line, isQuoted));
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }

  // Named entities that newsletter generators abuse as invisible fillers.
  static final _htmlEntities = <String, String>{
    '&zwnj;': '', '&zwj;': '', '&shy;': '',
    '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>',
    '&quot;': '"', '&#39;': "'", '&apos;': "'",
  };
  static final _numericEntity = RegExp(r'&#x?[0-9a-fA-F]+;');
  static final _zeroWidthChars =
      RegExp('[\u200b\u200c\u200d\ufeff]');

  /// Cleans up raw HTML entities that newsletter generators leave in the
  /// auto-generated text part. Named entities are replaced, numeric ones
  /// decoded, and leftover zero-width characters removed.
  String _cleanText(String raw) {
    var text = raw;
    _htmlEntities.forEach((entity, replacement) {
      if (text.contains(entity)) text = text.replaceAll(entity, replacement);
    });
    text = text.replaceAllMapped(_numericEntity, (m) {
      final body = m.group(0)!.substring(2, m.group(0)!.length - 1);
      final code = body.startsWith('x') || body.startsWith('X')
          ? int.tryParse(body.substring(1), radix: 16)
          : int.tryParse(body);
      if (code == null) return m.group(0)!;
      try {
        return String.fromCharCode(code);
      } catch (_) {
        return '';
      }
    });
    text = text.replaceAll(_zeroWidthChars, '');
    // Lines that are only whitespace after cleanup become real blank lines.
    text = text
        .split('\n')
        .map((line) => line.trim().isEmpty ? '' : line)
        .join('\n');
    // More than two consecutive blank lines are rarely intentional.
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  /// Shows only domain + shortened path instead of the full tracking URL.
  String _shortLinkLabel(String url) {
    final withScheme = url.startsWith('http') ? url : 'https://$url';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) return url;
    final host = uri.host.isNotEmpty ? uri.host : url;
    final rest = '${uri.path}${uri.query.isNotEmpty ? '?${uri.query}' : ''}';
    if (rest.isEmpty || rest == '/') return host;
    return '$host/…';
  }

  List<InlineSpan> _linkifiedLine(String line, bool isQuoted) {
    final quoteStyle = isQuoted
        ? const TextStyle(color: TF.text2, fontStyle: FontStyle.italic)
        : null;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _urlPattern.allMatches(line)) {
      var end = match.end;
      var url = match.group(0)!;
      final trailing = _trailingPunctuation.firstMatch(url);
      if (trailing != null) {
        url = url.substring(0, trailing.start);
        end -= trailing.group(0)!.length;
      }
      if (url.isEmpty) continue;
      if (match.start > last) {
        spans.add(TextSpan(
          text: line.substring(last, match.start),
          style: quoteStyle,
        ));
      }
      final tappableUrl = url.startsWith('http') ? url : 'https://$url';
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          final uri = Uri.tryParse(tappableUrl);
          if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
        };
      _linkRecognizers.add(recognizer);
      spans.add(TextSpan(
        text: _shortLinkLabel(url),
        style: const TextStyle(
          color: TF.accent,
          decoration: TextDecoration.underline,
        ),
        recognizer: recognizer,
      ));
      last = end;
    }
    if (last < line.length) {
      spans.add(TextSpan(text: line.substring(last), style: quoteStyle));
    }
    return spans;
  }

  Widget _meta(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 52,
              child: Text(label,
                  style: const TextStyle(color: TF.text2, fontSize: 12))),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: TF.accent2, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
