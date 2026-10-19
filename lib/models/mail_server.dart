/// Known IMAP server presets, mirroring the SERVERS dict in gmail_app.py.
class MailServer {
  final String key;
  final String label;
  final String imapServer;
  final int imapPort;

  const MailServer({
    required this.key,
    required this.label,
    required this.imapServer,
    required this.imapPort,
  });
}

/// The remembered provider key, coerced to one that actually exists.
///
/// A key from an older version — or none at all — must not reach the dropdown:
/// `DropdownButtonFormField` crashes when its value is missing from the items,
/// which would take down the entire provider-selection screen. Better to land
/// on Gmail than on a dead screen.
String validServerKey(String? key) =>
    kServers.containsKey(key) ? key! : 'gmail';

/// The 8 most common IMAP providers. The effective host/port always come
/// from the per-account config, so users can still override them manually
/// in the settings screen (e.g. for a different custom provider).
const Map<String, MailServer> kServers = {
  'gmail': MailServer(
    key: 'gmail',
    label: 'Gmail',
    imapServer: 'imap.gmail.com',
    imapPort: 993,
  ),
  'outlook': MailServer(
    key: 'outlook',
    label: 'Outlook / Hotmail',
    imapServer: 'outlook.office365.com',
    imapPort: 993,
  ),
  'yahoo': MailServer(
    key: 'yahoo',
    label: 'Yahoo',
    imapServer: 'imap.mail.yahoo.com',
    imapPort: 993,
  ),
  'gmx': MailServer(
    key: 'gmx',
    label: 'GMX',
    imapServer: 'imap.gmx.net',
    imapPort: 993,
  ),
  'webde': MailServer(
    key: 'webde',
    label: 'Web.de',
    imapServer: 'imap.web.de',
    imapPort: 993,
  ),
  'icloud': MailServer(
    key: 'icloud',
    label: 'iCloud',
    imapServer: 'imap.mail.me.com',
    imapPort: 993,
  ),
  'ttonline': MailServer(
    key: 'ttonline',
    label: 'T-Online',
    imapServer: 'secureimap.t-online.de',
    imapPort: 993,
  ),
  'freenet': MailServer(
    key: 'freenet',
    label: 'Freenet',
    imapServer: 'imap.freenet.de',
    imapPort: 993,
  ),
};
