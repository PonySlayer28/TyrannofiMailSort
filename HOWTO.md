# 🦖 TyrannoFi — How-To Guide

A step-by-step guide to installing TyrannoFi, connecting your mailbox and
sorting it by sender without losing mail.

> **Read this first.** TyrannoFi works directly on your live mailbox. Changes
> happen on the server and show up on every device you use. Read
> [Safety rules](#9-safety-rules) before your first bulk run.

---

## Contents

1. [Install the app](#1-install-the-app)
2. [Connect your mail account](#2-connect-your-mail-account)
3. [Choose a sorting mode](#3-choose-a-sorting-mode)
4. [Workflow A: sort by sender (simplest)](#4-workflow-a-sort-by-sender)
5. [Workflow B: sort with rules](#5-workflow-b-sort-with-rules)
6. [Clean up an existing folder structure](#6-clean-up-an-existing-folder-structure)
7. [Spam scanner](#7-spam-scanner)
8. [Reading mail](#8-reading-mail)
9. [Safety rules](#9-safety-rules)
10. [Backups and undo](#10-backups-and-undo)
11. [Emergency tools](#11-emergency-tools)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Install the app

TyrannoFi is an Android app (Android 7.0 or newer).

### Option A: download the APK (recommended)

1. On your phone, open the
   [latest release](https://github.com/PonySlayer28/TyrannofiMailSort/releases/latest)
   and download `TyrannoFi-<version>.apk`.
2. Open the downloaded file. Android asks you to allow "Install unknown apps"
   for your browser or file manager. Allow it, then tap **Install**.
3. Optional: compare the file's SHA-256 checksum with the one in the release
   notes.

Google Play Protect may warn that the app is from an unknown developer. That
is because it is not distributed through the Play Store.

### Option B: build it yourself

**You need:** Flutter SDK 3.x, Java 11+, and the Android SDK (downloads
automatically on the first build).

```bash
git clone https://github.com/PonySlayer28/TyrannofiMailSort.git
cd TyrannofiMailSort
flutter pub get
flutter build apk --release
```

Install it on your phone:

```bash
# Phone connected via USB with USB debugging enabled
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Or copy `app-release.apk` to the phone and open it in a file manager. You
may have to allow "Install unknown apps" for that file manager.

For signed release builds, see [BUILD.md](BUILD.md).

---

## 2. Connect your mail account

1. Open TyrannoFi and tap the **gear icon** (top right) or the
   **"No account configured"** card.
2. Under **Provider**, pick your mail provider. Presets are available for
   Gmail, Outlook/Hotmail, Yahoo, GMX, Web.de, iCloud, T-Online and Freenet.
   They fill in the IMAP host and port for you.
3. Enter your **email address** and **password**.
4. For other providers, pick any preset and overwrite **Host** and **Port**
   (port is almost always `993`).
5. Tap **Save**, then **Test connection**. You should see
   *"Connection successful!"*

### App passwords (Gmail, Yahoo, iCloud, Outlook)

Most large providers do not accept your normal password over IMAP. You need
an **app password**:

| Provider | Where |
|---|---|
| Gmail | Google Account → Security → 2-Step Verification (must be on) → App passwords |
| Yahoo | Account Security → Generate app password |
| iCloud | appleid.apple.com → Sign-In and Security → App-Specific Passwords |
| Outlook | Microsoft Account → Security → Advanced security options → App passwords |

GMX and Web.de: IMAP access must be enabled in the webmail settings first
(Settings → POP3/IMAP).

**Where your password lives:** in the Android Keystore (encrypted), never in
plain text. **Delete password** in Settings removes it.

Each provider keeps its own settings and rules. You switch between them with
the dropdown on the home screen.

---

## 3. Choose a sorting mode

TyrannoFi sorts in one of two ways. The switch is in
**Settings → Sorting → Sort by sender**. It takes effect immediately.

| | **Sort by sender** (switch on) | **Sort by rules** (switch off, default) |
|---|---|---|
| Folder is decided by | the sender's domain | your rule list |
| Unknown sender | gets its own new folder | stays in the inbox |
| Setup effort | none | create rules first |
| Example | `service@mail.amazon.de` → `Amazon` | `paypal` → `Finance/Paypal` |

Sender mode ignores the rule list but keeps it. You can switch back at any
time and your rules are still there.

**How domain → folder works:** subdomains and country endings are removed, so
`mail.amazon.de`, `amazon.com` and `amazon.co.uk` all become `Amazon`.
`info@finanzguru.de` and `customer@finanzguru.de` both go to `Finanzguru`.

---

## 4. Workflow A: sort by sender

Use this if you want one folder per sender and nothing else.

1. **Settings → Sorting →** turn on **Sort by sender**.
2. Go back to the home screen and tap **Sort & Clean Up**.
3. Tap **Run sort**. Every mail in the inbox moves to its sender's folder.
   Missing folders are created.

Progress is saved. If the app is closed or the connection drops, run it again
and it continues where it stopped.

From now on, run **Sort & Clean Up → Run sort** whenever you want the inbox
emptied.

---

## 5. Workflow B: sort with rules

Use this if you want your own folder names or a hierarchy
(e.g. `Shopping/Amazon`).

A rule reads: **"if the sender address contains X, move it to folder Y."**
Matching ignores case.

### Option 1: create rules from an inbox scan

1. Home → **Inbox Scan** → **Scan INBOX**. The app groups all inbox mails by
   sender domain and shows how many mails each one has.
2. Either tap the **⊕** button next to a domain to create a rule for it, or
   tap **Auto** (top right) to create rules for all domains at once.
3. Check the result under **Rules** and rename target folders as needed.

### Option 2: import from folders you already have

If you already sorted your mailbox by hand, the app can learn from it:

1. Home → **Rules** → **Import from existing folders**.
2. The app looks at which senders dominate each folder and turns them into
   rules.

(Also available as **Find rules** on the **Folders** screen. It only looks at
the newest mails per folder, so it is fast but not exhaustive.)

### Option 3: add rules by hand

Home → **Rules** → **+**

- **Sender contains:** e.g. `paypal`
- **Target folder:** e.g. `Finance/Paypal` (use `/` for subfolders)

### Managing rules

- Toggle a rule on or off with its switch. Only active rules are applied.
- The **remove duplicates** icon in the top bar removes rules that repeat.
- **Delete all** asks for confirmation and cannot be undone.

### Run it

Home → **Sort & Clean Up** → **Run sort**. All active rules are applied to
the inbox.

If a rule points at a folder that no longer exists (for example after a
merge), the app stops and offers **Repair and sort**. That redirects the rule
to the folder the mail now lives in. Without the repair, sorting would
recreate the deleted folder.

---

## 6. Clean up an existing folder structure

### Browse and fix individual folders

Home → **Folders** → **Scan folders** lists every folder with its mail count.
Tap a folder to open it:

- **Scan:** shows which sender domains are in the folder and flags mails
  that are in the wrong place (*"3× misplaced → should be: Amazon"*).
- **Sort:** applies your rules to every mail in this folder.
- **Fix:** moves misplaced mails to the folder their rule points to. Mails that
  match no rule for this folder go back to the inbox.
- Use the **⋮** menu on a domain to **Move to folder** or **Delete from
  folder**.
- The **envelope icon** opens the folder's mails for reading.

### Merge duplicate folders

If you have both `Amazon` (made by the app) and `Shopping/Amazon` (made by
you), the **Folders** screen shows a **Duplicates (n)** button.

1. Tap it to see the suggested pairs: `Amazon (120) → Shopping/Amazon (45)`.
2. Merge **one pair first** and check the result in your mail client.
3. Then use **Merge all** for the rest.

Pairs the app cannot decide on are listed as *"Ambiguous — please decide
manually"*.

> **Gmail:** labels with "Show in IMAP" turned off are invisible to the app.
> If a pair is missing, check Gmail → Settings → Labels.

### Rebuild the whole tree by sender

**Settings → Re-sort → Re-sort by sender** replaces your existing topic
folders with one folder per sender domain.

1. The screen lists all folders with their mail counts.
2. Pick a **small** folder and tap **Trial run**. Check the result.
3. Only after one trial run does **Re-sort all** unlock.

Mails with no usable sender go to the inbox. Empty folders are removed.
The run can be cancelled. It stops after the current folder, and folders that
are already done are remembered for the next run.

### Find and delete duplicate mails

Home → **Sort & Clean Up** → **Duplicates** → **Find**. The app finds real
duplicates across all folders (same Message-ID or same fingerprint). Check
the list, then tap **Delete**. One copy per group is kept.

---

## 7. Spam scanner

Home → **Spam Scanner**. Pick a scan mode:

| Mode | What it scans | Speed |
|---|---|---|
| **Smart** | Reuses the last inbox scan plus the newest 500 inbox mails | fast |
| **INBOX** | every inbox mail | medium |
| **All** | every folder | slow |

Tap **Start spam scan**. Each sender gets a **score from 0 to 100**, with the
reasons listed:

- listed on DNS blocklists (Spamhaus DBL, SURBL, abuse.ch)
- disposable / throwaway email domain
- spam keywords in the subject

Tap **Blacklist** on a sender to add it to your blacklist. You can also add
domains or addresses by hand.

The disposable-domain list is downloaded from GitHub and cached for 24 hours.
Use **Update** to refresh it.

---

## 8. Reading mail

Home → **Mailbox** opens the inbox (or open any folder from the **Folders**
screen).

- Tap a mail to read it. **Mark all as read** is in the top bar.
- Switch between **text** and **HTML** view with the toolbar icon.
- **Images are blocked by default.** Loading them tells the sender you opened
  the mail (tracking pixels). Tap the image icon to load them for one mail.
- Links show only the domain and a short path, so you can see where a link
  really goes.

---

## 9. Safety rules

The app is built around a few rules. Knowing them explains why some buttons
are disabled:

1. **It moves, it never deletes.** Sorting, merging and re-sorting only move
   mail. Only the actions explicitly called *Delete* remove anything.
2. **Gmail folders are labels.** Deleting a folder on Gmail only removes the
   label, but a mail with *no* label left can end up in the trash. The app
   therefore never leaves a mail without a folder; it rebuilds folder by
   folder instead.
3. **Every folder is backed up before it is touched.** See
   [Backups](#10-backups-and-undo).
4. **One folder first.** Bulk buttons stay locked until you have processed and
   checked a single folder.
5. **Drafts, Sent, Trash and Spam are never touched**, even when the server
   does not mark them as such.
6. **Cancelling is safe.** A run always stops between folders, never in the
   middle of one.

### Long runs

Large mailboxes (tens of thousands of mails) can take hours. After 30 seconds
the app shows a notification and runs as a foreground service so Android
does not stop it. You can leave the app. If it is stopped anyway, start the
same action again and it resumes.

**Tip:** keep the phone charging and on Wi-Fi for large runs.

---

## 10. Backups and undo

Before every merge, re-sort and bulk action, the app writes a backup file
with the Message-IDs of every mail in the folder. The mail server keeps no
history of which folder a mail came from, so these files are the only record.

**Settings → Backups → View backups** lists them. Tap **Share** to send them
to yourself (email, cloud storage, etc.).

There is no one-tap undo. The backups tell you (or a script) where each mail
used to be.

---

## 11. Emergency tools

**Settings → Last resort → Folder emergency tools.** Only for a folder
structure that is beyond repair. All three actions affect **every folder at
once**. The folder list with mail counts is saved first.

| Action | What happens | Reversible? |
|---|---|---|
| **Move everything back to inbox** | All mail moves to the inbox, empty folders are removed. No mail is deleted. | Yes: run *Sort* again |
| **Push all folders aside** | Every folder moves under a parent folder (default `Old`), e.g. `Amazon` → `Old/Amazon`. Mails stay where they are. | Partly |
| **Delete all folders** | Removes every folder. On Gmail the mails stay in *All Mail*. **On other providers the mails are deleted with the folder.** You must type `DELETE` to unlock it. | **No** |

If a sort went wrong, **Move everything back to inbox** is almost always what
you want.

---

## 12. Troubleshooting

| Problem | Fix |
|---|---|
| *"Please set up account + password first."* | Settings → enter email and password → Save. |
| Test connection fails on Gmail/Yahoo/iCloud/Outlook | Use an app password (see [section 2](#app-passwords-gmail-yahoo-icloud-outlook)). |
| Test connection fails on GMX/Web.de | Enable IMAP in the webmail settings. |
| Folder named `Co` or `Com` appears | Older versions turned `amazon.co.uk` into `Co`. See KNOWN_ISSUES.md, issue 13. Merge it into the right folder. |
| A merged folder comes back after sorting | A rule still points at it. Use **Repair** on the Folders screen or accept **Repair and sort**. |
| Gmail folder is missing in the app | Gmail → Settings → Labels → enable "Show in IMAP". |
| Sort stopped halfway | Run it again. Progress is saved. |
| Folder names with umlauts look wrong | Fixed (IMAP uses modified UTF-7). See KNOWN_ISSUES.md, issue 17. |

For every bug found so far, with cause and status, see
[KNOWN_ISSUES.md](KNOWN_ISSUES.md).
