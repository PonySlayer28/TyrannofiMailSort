# Known Issues

> **As of 2026-07-23, 20:30.** The rewrite is complete: **strict sender-based
> sorting**, one folder per sender domain, no more categories. Inbox (99 of 99)
> and folder tree have both been processed. The category tree is fully dissolved
> — after reloading, the depth-first sorted list begins with a flat folder,
> meaning no more `Category/Name` prefixes.
>
> The first batch run reported **592 of 605 folders done, 33,178 mails
> re-sorted, 13 skipped or incomplete**. A second cleanup run yielded **658 of
> 659 done, 0 mails re-sorted, 1 skipped** — the "0 re-sorted" confirms the
> first run was complete (nothing left to move), and of the 13 stalls, 12 ran
> cleanly on the second attempt. The remaining 1 is an edge case (snapshot or
> single move stalled), not a lost mail: the code only moves, never deletes,
> and a non-emptied folder stays put.
>
> This renders issues 3, 5 and the Audible trio moot: where there are no
> categories, there are no pairs to form and nothing to guess.

Found on a live mailbox (Gmail, ~681 labels, two sorting epochs). None of
these are specific to that account — they affect any user with a mature folder
structure.

The common root: **folder names are treated as strings, not as structured
paths.** Almost everything below follows from that.

---

## 1. Substring dedup swallows unrelated domains

`storage_service.dart` — `autoAssign` and `importRulesFromFolders` check
`existing.any((p) => dl.contains(p))`. Once a rule `auto` exists (from
`Tech/Auto`), every subsequent domain containing "auto" is dropped:
`meinauto.de`, `autodoc.de`, `atp-autoteile.de`, `autohaus-hohenbrunn.de`,
`autoservice-portal.de`. Similarly `Gaming/Steam` → `steamkeys`, `steampowered`,
`truesteamachievements` **and** `cbs-team`.

On the mailbox: 663 folders yielded only 501 rules.

**Status:** fixed. `patternMatchesDomain` in `domain_utils.dart`
compares whole dot- and hyphen-separated parts instead of substrings;
`patternMatchesSender` checks only the sender domain, not the full address.
Covered by tests. How many rules the 663 folders now produce will show on the
next import (see "Next Steps").

## 2. Provider pseudo-folders are not consistently recognized

`imap_service.dart` — `_normalizePath` normalizes `[Google Mail]/` to
`[Gmail]/`, but the skip list only knows these two spellings. Labels like
`[Imap]/Papierkorb`, `[Imap]/Entwürfe`, `[Imap]/Gesendet` pass as ordinary
folders and become rule sources.

**Status:** fixed. `_isProviderNamespace` now matches on any
bracket-enclosed root segment rather than a list of known names, at all five
sites that filter folders.

## 3. Arbitrary choice between duplicate folders

If the same sender exists in `Amazon` and `Shopping/Amazon`, whichever the
server lists first wins — not the one the user intends.

**Status:** fixed. `planFolderMerges` + `mergeFolder` resolve the duplication
instead of guessing a side. On the mailbox, all 101 visible pairs have been
merged; the app reports "No duplicates". Where no two folders compete, the rule
selection can no longer be arbitrary.

What remains duplicated is only invisible to the app — see issue 5.

## 4. `_domainToFolder` creates the duplication in the first place

`autoAssign` derives the target folder mechanically from the domain
(`absinth-oase.de` → `Absinth-oase`) and creates it alongside the manually
maintained category. This is the source of the 110 duplicate pairs.

**Status:** fixed. `autoAssign` now receives the existing folders
and prefers them as targets; categorized folders claim their name before flat
ones. New duplications no longer arise — existing ones remain until merged.

## 5. Not every Gmail label appears over IMAP

Seven labels are reported by the Gmail API but not by `LIST` over IMAP. After
merging all visible pairs, the cost is precisely these seven pairs remaining
duplicated, because their hierarchical counterpart does not exist for the app:

| Flat | Invisible target |
|---|---|
| `Xing` (1415) | `Social/Xing` |
| `Kraken` (819) | `Finanzen/Kraken` |
| `Flaconi` | `Shopping/Flaconi` |
| `Mastering` | `Musik/Mastering` |
| `Ing` | `Sport/ING` |
| `Plugin-alliance` | `Musik/PluginAlliance` |
| `Fabfilter` | `Musik/FabFilter` |

This makes the bug more expensive than expected: not one missing line but seven
pairs, the largest with 1,415 mails. The app still truthfully reports "No
duplicates" — it simply only sees one half.

**Hypothesis:** Gmail has a per-label "Show in IMAP" setting (Settings →
Labels). When disabled, the label does not exist for any IMAP client. This flag
is not visible through the API.

**Status:** unconfirmed but narrowed down. Only verifiable in Gmail's web
settings — check the setting on exactly these seven labels. If the hypothesis
holds, a checkmark per label suffices, and the app will find the pairs on its
own.

## 6. Sample size and threshold are implicitly coupled

`defaultRuleSampleSize = 1` only works because the caller passes `minCount: 1`.
Anyone changing the sample size must also change the threshold — nothing in the
code enforces this.

**Status:** fixed. `importRulesFromFolders` now derives the
threshold from `sampleSize` instead of accepting it separately.

## 7. No batch run for merges

Tapping through 101 pairs one by one is impractical; a batch run was missing.

**Status:** fixed. `mergeFolders` processes the list over a single
connection and checks for cancellation between folders, never within one. Run on
the mailbox: ten pairs, cleanly stopped.

## 9. Merging left rules pointing at deleted folders

`_mergeFolder` moved the mails and deleted the flat folder but did not redirect
the rules. After the 101 merges, **76 of 520 rules** pointed at nothing —
`amazon → Amazon`, `paypal → Paypal`, `mut → Mut`. The next sort run would have
recreated exactly those 76 folders and largely undone the merge.

Caught before the first sort, not after: the observation that "find rules"
produced only 19 new rules led to the count.

**Status:** fixed. `_mergeFolder` now redirects rules as soon as all mails have
arrived — on a partial move it does not, since the source folder is still the
correct address for the remainder. For damage already done, "N rules to repair"
appears on the folder screen: visible only when there is something to repair.
`planRuleRepairs` finds the new target by the same rule that pairs folders,
leaves ambiguous cases alone, and does not touch rules pointing at never-created
folders.

Run on the mailbox: 76 redirected, no rule points at a deleted folder
afterwards, and the count stayed at 520 — no rule was duplicated.

## 10. "Delete all labels, then re-sort" leads to trash

The obvious path to a clean sort — delete all folders first, then re-sort
everything — is a trap on Gmail, and a silent one.

Without a label, a mail only exists in "All Mail". The sort run would have to
fetch it from there. But `_moveUid` uses `MOVE` (or `COPY` + `\Deleted`), and a
MOVE **out of** "All Mail" means "remove from archive" to Gmail — i.e. trash.
At the scale of a real mailbox, this is not a residual risk.

The app currently prevents this only as a side effect: `_isSpecialUseMailbox`
filters All Mail via `MailboxFlag.all` as both source and target. Anyone
loosening this filter to "finally sort All Mail too" reopens the trap.

**Status:** worked around, not fixed — the "no label at all" state is never
created. `resortAllFolders` rebuilds the tree folder by folder instead: mails
move directly from the old folder to the sender-named one, and the emptied
source folder is deleted afterwards. Moves happen exclusively between ordinary
folders; All Mail is never touched. Mails without a parseable sender go to the
inbox — a defined collecting point rather than leaving leftovers in a folder
that is about to disappear.

## 11. `sortInbox` trusted the folder cache

The same bug as in `resortAllFolders`, only at the most frequently executed
site: `created` was pre-populated from the folder cache. That cache still lists
the 101 flat folders that the merges deleted — exactly the names a sort would
target. The `CREATE` would have been skipped and every mail destined for
`Amazon` or `Paypal` left behind. Nothing would have broken, but the run would
have silently done nothing on the largest items.

**Status:** fixed. `created` starts empty; a failed move creates the folder and
retries.

## 12. A rule targeting `INBOX` copied instead of moving

`sortInbox` invoked the move even when source and target were both the inbox.
But `_moveUid` is `MOVE` or `COPY` + `\Deleted` — "moving" a mail in the inbox
to `INBOX` means: create a copy, mark the original for deletion. Such rules
arise not manually but through `fixFolder`, which returns misplaced items with
target `INBOX`.

**Status:** fixed. `target == 'INBOX'` is now skipped instead of triggering a
self-move.

## 13. `.co.uk` landed in the catch-all folder `Co`

`extractBaseDomain` always took the last two dot-separated parts. For two-part
country suffixes, this names no one: `amazon.co.uk` → `co.uk` → folder `Co`.
Every British, Australian and Japanese sender would have ended up in the same
folder, and during a batch run over all folders, `Co` would have grown with
every pass.

Inherited from `gmail_app.py`, where the same line exists — in the old tool it
went unnoticed because only domains with an existing rule became folders.

**Status:** fixed. If the domain ends with a known two-part suffix, the cut is
shifted one part to the left. The list covers common countries, not all — it
is an approximation of the Public Suffix List, which has thousands of entries
and would need maintenance. A missing suffix costs a strangely named folder,
not a lost mail. Covered by tests.

## 14. The Drafts folder entered the batch run as an ordinary folder

`_ordinaryMailboxes` filters INBOX, bracket-enclosed provider namespaces, and
server-flagged special-use mailboxes — **but not by name**. The mailbox
contained a plain top-level `Entwürfe` (German for "Drafts") with no `\Drafts`
flag. It entered the sender-based batch run as an ordinary folder.

What that would have meant: sorting drafts by their *sender* means distributing
them across foreign-domain folders. And `deleteAllFolders` on the emergency
screen would have deleted the folder — the same function feeds both.

**Only noticed because it failed:** the folder reported
`not backed up: BAD Could not parse command` and was thus the one incomplete
case in both batch runs. The root cause of the command error is the umlaut —
IMAP requires folder names in modified UTF-7, but the `ü` was sent raw. The
error protected the drafts.

**Status:** fixed. `isReservedMailboxName` in `domain_utils.dart` knows
Entwürfe/Drafts, Gesendet/Sent, Papierkorb/Trash, Junk/Spam, Archiv/Archive
and Postausgang/Outbox in both English and German, and checks both the full path
and the last segment (so `Alt/Entwürfe` after a push-aside is also caught).
`_ordinaryMailboxes` excludes them — protecting batch runs, renames, deletes and
the folder snapshot alike. Covered by tests.

**The command error itself is fixed separately** — see issue 17.

## 15. A long run did not survive switching away

The app did not register with Android as a running service — only `INTERNET` and
`ACCESS_NETWORK_STATE` were declared in the manifest. During a sort run, it was
an ordinary background app: Android could kill it as soon as it needed memory,
and after a few minutes with the screen off, Doze additionally throttled the
connection.

For a multi-hour run, "may be killed" practically means "will be killed".
Nothing broke — each move is atomic, the backup is written before each folder —
but of the three run types, only `sortInbox` was resumable; folder scan and
`resortAllFolders` started over.

**Status:** fixed. `LongRunService` (Kotlin, in its own app module) is a
foreground service of type `dataSync`; `LongRunGuard` (Dart) starts it once an
operation survives **30 seconds** and stops it afterwards.

Three key decisions:

- **Native, not a plugin.** A third-party package would bring its own Kotlin
  Gradle Plugin — exactly the problem in issue 8. The app's own module already
  has Kotlin configured.
- **Threshold, not immediate.** A notification that flashes on every short
  action gets muted — and then doesn't help during hour-long runs either.
- **Attached to `_connect`/`_logout`, not to individual methods.** Every long
  operation holds a connection for exactly as long as it works. A hook on login
  and logout covers all 25 operations and any future ones automatically, rather
  than a list of method names someone forgets to extend.

The notification permission (Android 13+) is requested but not enforced: if
denied, the progress notification is invisible — the service still runs, and
only the service protects the process. Covered by six tests, including nesting,
thrown exceptions and unpaired ends.

**Open:** folder scan and `resortAllFolders` still do not persist their
progress. The foreground service makes interruption unlikely but not impossible
— for a mailbox without folders it only affects `sortInbox`, which is resumable.

## 16. There was no way back

Every mass operation only moved forward. If a sort went wrong, the user was left
with a structure they did not want — the two existing emergency tools ("push
aside", "delete all folders") are themselves irreversible and do not solve the
problem.

**Status:** fixed. `resetAllToInbox` empties every ordinary folder into the
inbox and deletes the emptied folders. On the emergency screen as the first
card, green-bordered instead of red: anyone landing there in a panic should see
the reversible option before the two irreversible ones.

**Why this is actually a way back and not another one-way street:** No mail is
deleted, it only loses its classification. And since the sort is a pure function
of the sender, a new run restores the same tree. It is the only mass operation
in the app whose effect can be undone.

**What it does not touch makes it safe.** Three ways to destroy a mailbox are
excluded — and the guarantee is now testable instead of spread across the code:
`isProtectedMailboxPath` in `domain_utils.dart` consolidates them and is covered
by tests.

| Excluded | What would otherwise happen |
|---|---|
| `INBOX` itself | Moving to itself = copy + delete original |
| `[Gmail]/…` and other bracket namespaces | Moving **out of** "All Mail" = trash (issue 10) |
| Drafts, Sent, Trash, Spam | Emptying Sent into the inbox would be its own disaster (issue 14) |

Message-ID backup before each folder, cancellation at folder boundaries, never
within a folder — the same design as the sort batch run. The foreground service
from issue 15 applies automatically.

**Untested:** not run on the live mailbox. The code is the same that moved
33,178 mails — `_resortFolder` with a fixed target instead of sender evaluation
— but a run on the live mailbox was deliberately not performed.

## 17. Folder names were sent unencoded

IMAP carries folder names not in UTF-8 but in **modified UTF-7** (RFC 3501
§5.1.3): `Entwürfe` on the wire becomes `Entw&APw-rfe`, and a literal `&`
doubles to `&-`. A raw name is therefore not a slightly wrong name — the server
cannot parse the entire command and responds `BAD Could not parse command`.
This is exactly what `Entwürfe` reported, the one incomplete case in both batch
runs (issue 14).

**Why it went unnoticed despite the library having an encoder:** `enough_mail`
encodes at some call sites and not others, and the difference is invisible at
the call:

| Call | Encodes |
|---|---|
| `selectMailboxByPath(path)` | nothing — the argument **is** the wire form |
| `createMailbox(path)` | only the last segment |
| `renameMailbox(box, new)` | only the last segment of `new` |
| `uidMove`/`uidCopy(targetMailboxPath:)` | only the last segment |
| `deleteMailbox(box)` | nothing — takes `box.encodedPath` |

All paths in the app come from `Mailbox.path` and are thus **decoded** —
correct for display and comparison, wrong for sending. Every
`selectMailboxByPath` sent them unchanged. And since the encoding calls only
handle the last segment, `Bücher/Amazon` would also have failed: child encoded,
parent raw.

**Fixed.** `lib/utils/imap_path.dart` encodes at the boundary — where a path
becomes a command, nowhere else. Two functions instead of one because the library
is inconsistent: `encodeMailboxPath` (every segment) for calls that encode
nothing; `encodeMailboxParents` (everything except the last segment) for calls
that handle the last segment themselves. Passing a pre-encoded path to the
second kind would double-encode it — the `&` from the first pass would become
`&-` in the second, and `Entw&APw-rfe` would arrive as `Entw&-APw-rfe`.

The separator is queried from the server rather than assumed to be `/`; a server
using `.` would otherwise split the path at the wrong point.

Nine tests cover it, including the round-trip (encode → `Mailbox` → displayed
name matches original) and **the assumption itself**: that `Mailbox.encode` only
touches content after the last separator. If a future `enough_mail` version
changes that, the test breaks instead of silently double-encoding every folder
with a non-ASCII character.

**Practical impact:** app-generated names are almost always ASCII, but not
necessarily — `safeFolderSegment` preserves letters, so a domain `münchen.de`
produces the folder `München`. Affected were all manually created folders with
non-ASCII characters: they could not be selected, renamed, or addressed as
targets.

## 18. The two cosmetic issues — and what hid behind the second one

**"Connected! 0 rules active."** The zero was hardcoded, always wrong, and
doubly meaningless in sender mode: no rule is read there. The message now states
what the run actually uses — the number of active rules or "Sorting by sender".

**The re-sort screen lost all mail counts after the first run.** This was not a
display bug but `invalidateFolderCache`: it **deleted** the entry. This left
`loadFolderCache(..., allowStale: true)` with nothing to return — the parameter
was a promise the storage could not keep. Affected was not only the count
column, but also the fallback in `listFolders`: if a `LIST` fails, the app
should show the previous list instead of an error, and after every merge it
could no longer do so.

**Fixed:** invalidation now **marks** instead of deleting — the folder list
stays, the timestamp drops to zero.

**Nothing is loosened by this**, and that is exactly what matters: the normal
read path still returns `null`, because a timestamp of zero is older than any
TTL. `known`, `created` and everything else that must not trust the cache still
cannot trust it (issue 11). Only callers that explicitly ask for stale data
receive it.

Because this is a guarantee, not a detail, both decisions are extracted as pure
functions and covered by tests: `folderCacheIsFresh` (an invalidated entry
counts as fresh under *no* conceivable clock) and `staleFolderCacheEntry` (the
list stays, the timestamp goes).

**Side finding:** `storage_service.dart` contained two literal null bytes — as
delimiters in a dedup key, written raw instead of as `\u0000`. Dart handles
both identically, but tools do not: `grep` treated the file as binary and
**silently** skipped it, so a search for `invalidateFolderCache` found nothing.
Replaced with the escape notation; the string value does not change, the file is
text again.

## 19. The batch run remembered nothing

The inbox run was resumable from the start: it processes UIDs and can track
which ones are done. The folder batch run processes folders — and remembered
nothing. **Five hours of work, and an interruption started over at the first
folder.** The foreground service (issue 15) made this unlikely, not impossible,
and over five hours that is a difference.

**Fixed.** Every folder that returns without error is noted; a later run skips
what has been noted.

**Two decisions everything hinges on:**

1. **Noted after the folder, never before.** The reverse would be the dangerous
   order: an interruption mid-folder would mark it as done, and whatever remains
   inside would never be looked at again.
2. **Only error-free folders are noted**, so failed ones are retried. This is
   exactly what the second batch run did manually, and 12 of the 13 stalls ran
   cleanly.

A run that completes to the end clears the notes — an interrupted one leaves
them. The re-sort screen reads them on open and shows completed folders in green
as "completed in a previous run" instead of offering them again. The gate before
the batch button is lifted: an interrupted run *was* the trial run, its results
were on screen. Demanding the same proof twice would be punitive.

## 20. The 501 rules could only be deleted one by one

The rules screen could remove each rule individually. With 501 rules, that is
not a real option — the list could practically only grow.

**Fixed:** "Delete all rules" on the rules screen, visible only when there is
something to delete.

The warning states what actually changes, and it is not the sort order: in
sender mode, no rule is read anyway, so no mail moves differently. **What is
lost is the way back** — as long as the list exists, sender mode can be
disabled and the rules are unchanged. Without the list, switching back is a
fresh start from zero. In rule mode the dialog says something different, because
something different is true: without rules, every mail stays in the inbox.

## 21. The last button was hidden under the navigation bar

On the settings screen, "Folder emergency tools" — the last entry — was only
half visible: Android overlays its navigation bar at the bottom edge, and the
button sat underneath it.

**The cause is not specific to this screen.** The entire app has **no**
`SafeArea` anywhere, and **nowhere** is `MediaQuery.padding` read. Every
scrolling list guesses its bottom inset as a fixed number. Most guess 24 or 32
pixels and barely get away with it; two guessed 16, and there it shows:

- `settings_screen.dart` — the reported case
- `maintenance_screen.dart` ("Sort & Clean") — same line, previously unnoticed
  because the bottom holds text, not a button

**Fixed** in both: the bottom inset now queries the system value instead of
guessing.

```dart
padding: EdgeInsets.fromLTRB(
    16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
```

This adapts automatically — gesture navigation needs little, the classic
three-button bar needs more, devices without a bar need nothing.

**Why this particular button was the worst one to hide:** it leads to the
emergency tools, where folders are pushed aside or deleted. A half-visible
button invites mistaps.

## 22. Every start began at Gmail again

`app_state.dart` held the selected provider in a plain field:

```dart
String _serverKey = 'gmail';
```

It was never persisted. Every start began at Gmail — and anyone whose mailbox is
with another provider saw **"No account configured"**.

**Nothing was ever lost.** `configs.hive` stores each provider separately, the
password is in `FlutterSecureStorage`; switching brought everything back. That
is exactly what makes the bug insidious: the message reads like data loss.
Anyone who re-enters their credentials in response reaches their goal but
puzzled over something that was never broken.

It only surfaced now because Gmail was always used — the default happened to be
correct. With a Yahoo account, it shows on the first restart.

**Fixed:** the key is stored in the existing `misc.hive`, `init()` reads it,
`selectServer()` writes it.

**With a guard**, and it is not decorative: a stored key from an older version
would otherwise enter the selection list, and `DropdownButtonFormField` crashes
when its value is not among the items. That would break the provider switch
entirely — a worse bug than the one fixed here. `validServerKey()` maps anything
unknown back to `gmail`; five tests cover it, including empty string and `null`.

Verified on a Galaxy S21 FE: select Yahoo, `am force-stop` (PID empty
afterwards), restart — Yahoo is back. `misc.hive` shows the sequence
`gmail → yahoo → yahoo`.

## 8. Kotlin Gradle Plugin outdated

The build warns: migration to built-in Kotlin is needed, or future Flutter
versions will break.

**Status:** open — blocked externally, not by this project. The migration was
attempted and reverted (`android.builtInKotlin=true`, no more `kotlin-android`,
`kotlinOptions` as `kotlin { compilerOptions }`). It does not fail on the app's
own code: `FlutterPluginUtils.detectApplyingKotlinGradlePlugin` in the Flutter
SDK applies `kotlin-android` to every plugin subproject that does not bring its
own KGP — and that is exactly what AGP 9 rejects. The build then breaks in
third-party packages (starting with `flutter_secure_storage`), which cannot be
changed here. This is why the Flutter template itself sets
`android.builtInKotlin=false`.

To be revisited once the Flutter SDK disables this automatic application. Until
then, the warning remains; the build completes cleanly.

**Re-checked on 2026-08-03** — with Flutter 3.44.6, AGP 9.0.1, KGP 2.3.20.
The finding is unchanged but now documented with exact error messages.
`android.builtInKotlin=true` alone fails on the app's own module, which still
carries `kotlin-android`. Removing it and switching `kotlinOptions` to
`kotlin { compilerOptions }` shifts the failure to where it cannot be fixed:

```
A problem occurred evaluating project ':flutter_secure_storage'.
> Failed to apply plugin 'com.android.internal.library'.
   > java.lang.IllegalStateException: The 'org.jetbrains.kotlin.android' plugin
     is no longer required for Kotlin support since AGP 9.0.
     Solution:
       - Migrate this project to built-in Kotlin
       - Or set 'android.builtInKotlin=false' and 'android.newDsl=false'
```

The suggested setting is exactly what is already in place. And
`FlutterPluginUtils.detectApplyingKotlinGradlePlugin` remains unchanged in the
SDK. Both changes reverted, the build runs cleanly again.

---

# Next Steps

**None that require code changes.** Two items remain that need manual action on
the device or in a web interface:

1. **Delete the 501 rules** — the button exists (issue 20), but has not been
   tapped yet. The rules live in the app's on-device database; they cannot be
   reached from a computer. One tap on "Delete all rules" on the rules screen
   and it is done.

2. **Check issue 5** — if the seven IMAP-invisible labels should ever surface
   again: Gmail Settings → Labels → "Show in IMAP". Practically moot since
   categories no longer exist.

Externally blocked: issue 8. As a future idea: batching moves by target folder
instead of one per mail — the `Shopping/PayPal` case with 6,538 individual
commands was the most expensive item in the first batch run. Deliberately not
touched: this is the one code path that moved 33,178 mails, and there is no
mailbox available to test changes against. Speed is not a reason to modify it
while that is the case.
