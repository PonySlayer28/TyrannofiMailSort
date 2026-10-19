// How a mailbox name has to look on the wire.

import 'package:enough_mail/enough_mail.dart';

/// IMAP does not carry mailbox names as UTF-8. RFC 3501 §5.1.3 puts them in
/// *modified UTF-7*: `Entwürfe` travels as `Entw&APw-fe`, and a literal `&`
/// doubles to `&-`. A name that goes out raw is not a mildly wrong name — the
/// server cannot parse the command at all and answers `BAD Could not parse
/// command`. That is the error the live mailbox returned for `Entwürfe`, the
/// one folder that stayed unfinished in both bulk runs (KNOWN_ISSUES 14).
///
/// Every path this app holds is *decoded*: `Mailbox.path` from `listMailboxes`
/// has been through the codec already, and that is the right form to show and
/// to compare. Encoding therefore belongs at the edge — the moment a path is
/// handed to a command — and nowhere else.
///
/// `enough_mail` does part of this itself, but only part, and the split is not
/// obvious from the call:
///
/// | Call | Encodes |
/// |---|---|
/// | `selectMailboxByPath(path)` | nothing — the argument *is* the wire form |
/// | `createMailbox(path)` | the last segment |
/// | `renameMailbox(box, newName)` | the last segment of `newName` |
/// | `uidMove`/`uidCopy(targetMailboxPath:)` | the last segment |
/// | `deleteMailbox(box)` | nothing — uses `box.encodedPath` |
///
/// Hence two functions rather than one: [encodeMailboxPath] for the calls that
/// encode nothing, [encodeMailboxParents] for those that take the last segment
/// themselves. Handing a fully encoded path to the latter would encode it
/// twice — the `&` of the first pass becomes `&-` in the second, and
/// `Entw&APw-fe` arrives as `Entw&-APw-fe`.

/// Encode every segment of [path] for the wire.
///
/// Segment by segment, because `Mailbox.encode` stops at the last separator
/// and leaves everything to its left alone — which loses `Bücher` in
/// `Bücher/Amazon`. Pure ASCII passes through unchanged, so calling this on a
/// path that needs nothing costs nothing.
String encodeMailboxPath(String path, String separator) => path
    .split(separator)
    .map((segment) => Mailbox.encode(segment, separator))
    .join(separator);

/// Encode every segment of [path] *except* the last one.
///
/// For the calls that encode the last segment themselves. Their pass runs over
/// the whole string, but only ever touches what follows the final separator —
/// so the segments encoded here reach the wire as they are. `imap_path_test`
/// nails that behaviour down: if a future `enough_mail` starts encoding the
/// full path, the double encoding this avoids would otherwise return silently.
String encodeMailboxParents(String path, String separator) {
  final cut = path.lastIndexOf(separator);
  if (cut == -1) return path;
  final parents = encodeMailboxPath(path.substring(0, cut), separator);
  return '$parents$separator${path.substring(cut + separator.length)}';
}
