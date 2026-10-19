# TyrannoFi

A Flutter/Android app that organizes your IMAP mailbox by sender domain:
one folder per domain, no categories. `service@mail.amazon.de` →
`Amazon`, and `info@finanzguru.de` plus `customer@finanzguru.de` both land
in the same folder.

## Features

- **Sort by sender** — inbox or entire folder tree.
- **Merge duplicate folders** (`Amazon` and `Shopping/Amazon`).
- **Rules** as an alternative to sender mode, importable from existing folders.
- **Spam scanner** — DNS blocklist checks (Spamhaus, SURBL, abuse.ch),
  disposable-domain detection, keyword scoring.
- **Emergency tools**: move everything back to inbox (reversible), push the
  tree aside, delete all folders.

## Design Principles

This tool operates on a live mailbox, and that shapes the entire design:

1. **It moves, it never deletes.** On Gmail, folders are labels — deleting a
   folder only removes a mail's classification.
2. **The "no label at all" state is never created.** A `MOVE` out of "All Mail"
   on Gmail means trash, not relabeling. The tree is rebuilt folder by folder
   instead.
3. **Every folder is backed up before it is touched.** Its message IDs are saved
   as a JSON file on the device before any mail moves.
4. **One folder must run before the batch is unlocked.** The batch button stays
   disabled until a single folder has been processed and its result reviewed.
5. **Drafts, Sent, Trash and Spam are never touched** — even when the server
   does not flag them as such.

Cancellation always happens at folder boundaries, never mid-folder. Long-running
operations register as a foreground service so Android does not kill them, and
they are resumable.

## Build

```sh
flutter pub get
flutter test
flutter build apk --debug
```

For a signed release build, see [BUILD.md](BUILD.md).

## Documentation

- **[HOWTO.md](HOWTO.md)** — step-by-step user guide: install, connect your
  account, sort, clean up, spam scanner, backups and emergency tools.
- **[KNOWN_ISSUES.md](KNOWN_ISSUES.md)** — every bug found during real-world
  usage, with root cause, impact and status. Most come from running the app on
  a mature mailbox and affect any user with a grown folder structure.

Particularly worth reading if you are building something similar: issue 10
(why "delete all and re-sort" leads to trash on Gmail), issue 13
(`amazon.co.uk` → folder `Co`), and issue 17 (IMAP requires folder names in
modified UTF-7).

## License

MIT — see [LICENSE](LICENSE).
