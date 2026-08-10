# sops-macos-gui — a walkthrough

Every screen, every control, in the order you meet them.

## About the pictures

They are **renders of the app's own views**, produced by
`./Scripts/guide-snapshots.sh`, not screenshots of a running window.

That is not a stylistic choice. On the machine this project is developed from,
the agent shell runs in a `Background` launchd session, so a window can be
created and registered with the window server but is never composited —
`screencapture` on it returns a black rectangle or an unrelated icon. Rather
than ship images that were quietly wrong, the guide renders each view offscreen
through a real `NSHostingView`. Same SwiftUI code, same layout engine, same
fonts; what you lose is the surrounding window chrome and anything that only
exists mid-interaction (a text cursor, a hover highlight, a scrolled-down list).

One consequence worth stating: `NavigationSplitView`'s own sidebar column does
not populate under that technique, so the sidebar below is rendered from
`SectionSidebarList` standing on its own. It is the same type the app puts in
that column, not a mock-up.

The data in every picture is a throwaway: keys generated per render by
`age-keygen` and discarded when the process exits, hostnames under `.invalid`
(RFC 6761 — guaranteed never to resolve), and API keys with `DEMO` where the
entropy would be. Nothing here decrypts anything.

---

## Follow along: the walkthrough project

Optional, but the pictures below are of exactly this. It takes a minute:

```bash
mkdir -p ~/Development/sops-demo-project/{config,services}
cd ~/Development/sops-demo-project

# A key for this walkthrough and nothing else.
age-keygen -o demo-age-key.txt
PUB=$(grep '^# public key:' demo-age-key.txt | cut -d' ' -f4)

cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: \.secrets\.yaml$
    age: $PUB
  - path_regex: \.secrets\.env$
    age: $PUB
EOF

cat > config/production.secrets.yaml <<'EOF'
database:
  url: postgres://demo:not-a-real-password@db.example.invalid:5432/demo
  pool_size: 20
api:
  stripe_key: sk_live_DEMOxxxxxxxxxxxxxxxxxxxx
  sendgrid_key: SG.DEMOxxxxxxxxxxxxxxxxxxxx
feature_flags:
  - new-checkout
  - beta-search
EOF

cat > config/staging.secrets.yaml <<'EOF'
database:
  url: postgres://demo:staging-not-real@db.staging.example.invalid:5432/demo
api:
  stripe_key: sk_test_DEMOxxxxxxxxxxxxxxxxxxxx
EOF

cat > services/worker.secrets.env <<'EOF'
REDIS_URL=redis://cache.example.invalid:6379/0
WORKER_TOKEN=demo-worker-token-0000
EOF

echo demo-age-key.txt > .gitignore

for f in config/*.secrets.yaml services/worker.secrets.env; do
  sops --encrypt --in-place "$f"
done

git init -q . && git add -A && git commit -qm "Demo project"
```

`demo-age-key.txt` is in `.gitignore` on purpose, and the guide will not ask you
to put it anywhere the app can read it from disk. Keys go in by paste, once per
launch — see step 16.

---

## Part 1 — First launch

The wizard runs once. It checks the machine and never changes it: nothing is
installed, nothing is written outside the app's own preferences. Where something
is missing, you get an explanation and a command to copy, and you decide.

### Step 1 · Welcome

![Welcome](images/guide-01-welcome.png)

Three buttons sit at the bottom of every step: **Back**, **Check Again**, and
**Continue**. Nothing here is also in Settings › Health by accident — it is the
same check running from the same code, so anything you leave unresolved now is
still there later.

### Step 2 · Command line tools

![Tools](images/guide-02-tools.png)

Whether `sops` and `age` are on your `PATH`, and which versions.

The app **does not need them** to work, and the step says so: *"Optional, but
the Help snippets rely on them."* It carries its own sops engine, in process
(`docs/adr/0001`). This step is about the *other* tools you use on the same
files — the snippets in Help run in your terminal and in CI, against the same
files, and a `sops` older than the one baked in here may not understand what
this app writes.

**Check Again** re-runs the scan without restarting the wizard. That button
exists because the natural move on seeing an orange row is to install the thing
in another terminal and come back — before it, coming back showed you the stale
answer.

### Step 3 · Engine

![Engine](images/guide-03-engine.png)

The built-in sops and age versions. Informational; there is nothing to fix.

### Step 4 · Security

![Security](images/guide-04-security.png)

Whether an age identity is available to this session. Expect a finding here on
first run — you have not pasted one yet. Step 16 is where that happens.

### Step 5 · Projects

![Projects](images/guide-05-projects.png)

Per-project findings: recipients that no longer match `.sops.yaml`, files
encrypted to a key you do not hold, that sort of thing.

On a genuinely first run this is empty — there is no project yet. The picture
shows a machine that already has one, because an empty list would tell you
nothing about what a finding looks like.

### Step 6 · Summary

![Summary](images/guide-06-summary.png)

Everything above, in one list, under a one-line verdict. **Done** closes the
wizard; **Check Again** re-runs everything.

*"Some things need fixing"* is not a block — the line underneath says so
explicitly. Each row carries its own explanation, what the scan did **not**
look at (`node_modules` and friends are always skipped, and the row says so
rather than letting you read a clean result as a complete one), and a command
you can copy.

---

## Part 2 — Getting around

### Step 7 · The sidebar

![Sidebar, Projects selected](images/guide-07-sidebar.png)

Three destinations. **Projects** is the work; **About** and **Settings** sit in
their own group at the bottom, the way macOS sidebars separate secondary
destinations.

Rows are selectable across their **full width** — click anywhere in the row, not
only on the label. (They were not, once. About and Settings were hand-rolled
buttons that only took a click where the text drew, 58 pt of target in a 220 pt
sidebar.)

![Sidebar, About selected](images/guide-07-sidebar-about.png)

Selecting About or Settings shows that page **in the main window**, and the
project column disappears while you are there — a list you cannot act on without
leaving the page you came to read is not worth the width.

If you have unsaved changes in an open file, changing sections asks first:
**Save and continue**, **Discard changes**, or **Cancel**. Nothing is discarded
silently.

### Step 8 · The project list

![Project list](images/guide-08-projects.png)

Projects you have added. **Add Project…** at the bottom opens a folder chooser —
point it at `~/Development/sops-demo-project`.

A project is just a directory the app remembers. It is not copied, not indexed,
and not modified by being added.

Git worktrees of the same repository are grouped together, so a repo with four
checked-out branches is one heading rather than four unrelated rows.

### Step 9 · The file list

![File list](images/guide-09-files.png)

Every sops-encrypted YAML file under the project root, by path. Click one to
open it.

The footnote at the bottom is doing real work: this app opens **YAML only** in
v1. `services/worker.secrets.env` is a genuine sops file that sops itself wrote,
and it is deliberately counted-but-not-listed rather than hidden — a file you
can see in Finder silently missing from the list is the worse outcome.

---

## Part 3 — The editor

### Step 10 · An open file

![Editor](images/guide-10-editor.png)

Decryption happens in process, using the identity you gave the app for this
session. The key never goes through the environment and never reaches a
subprocess (`docs/adr/0001`).

Each row is one leaf of the document:

| Column | What it is |
|---|---|
| Left, monospaced | The key path — `database.url`, `feature_flags.0` |
| Below it | The YAML type (`string`, `integer`, …) and a padlock meaning encrypted at rest |
| Middle | The value, **masked by default** |
| 👁 | Reveal / hide this one row |
| ⧉ | Copy this value to the clipboard without revealing it |

Values are masked even though the file is already decrypted in memory. The
threat this addresses is the one in the room: a screen share, a colleague behind
you, a recording.

Toolbar, top right: **−** removes the selected row, **+** adds one, **Save**
writes the file back. All three are disabled until they would do something.

### Step 11 · Revealing a value

![Revealed row](images/guide-11-editor-revealed.png)

Click 👁 on a row and that row — only that row — shows plaintext. The icon
becomes a struck-through eye; click it again to hide.

Revealing is per row and does not survive a save.

### Step 12 · Editing

![Unsaved changes](images/guide-12-editor-edited.png)

Type in a value field. The header picks up an orange dot and **Unsaved
changes**, and **Save** becomes enabled.

Note what this picture had to do to be useful: the edited row is *revealed*. An
edited row is masked like any other, so with it hidden the only sign of your
change is the header badge.

Until you press Save, nothing on disk has changed. Trying to leave — another
file, another project, another section, ⌘W, ⌘Q — prompts first.

Saving re-encrypts through the same in-process engine, to the recipients in the
file's own `sops` block. Recipients are preserved; the app does not silently
re-target a file at your key.

### Step 13 · No key yet

![Needs a key](images/guide-13-editor-needs-key.png)

Opening a file with no identity configured looks like this: *"No decryption key
configured — Add your age private key in Settings › Key to open this file."*

It is not an error, and it deliberately does not read like one. You have not
given the app a key yet; step 16 is where you do.

### Step 14 · Adding a row

![Add row](images/guide-14-add-row.png)

**+** opens this sheet. Give the new entry a key and a type; where the selection
sits in a list rather than a map, the sheet appends instead of asking for a name.

The new row is marked **New** until saved. Removing a row is **−**, and it too
is a pending change until Save.

---

## Part 4 — Settings and About

### Step 15 · Settings › Health

![Settings](images/guide-15-settings.png)

Reached from the sidebar or with ⌘, — the same pane either way, in the main
window. Three tabs: **Health**, **Key**, **Updates**. Steps 16 and 17 are the
other two.

Health is the wizard's checks, grouped the same way and re-runnable at any time
with **Re-run checks** at the bottom. Each finding is a status, what was found,
what it means, and — where there is one — a command in a box with **Copy** beside
it.

Copy is as far as it goes. The app never runs those commands for you: no
installers, no package managers, no `sudo`. Reading your machine is the whole of
what this pane does.

Note the "Embedded age" row in the picture: it reports what it *has not* done —
*"Update checks are turned off in Settings, so this app has not asked GitHub."*
A check that cannot run says so rather than reporting a green tick it did not
earn.

### Step 16 · Settings › Key

![Key import](images/guide-16-key-import.png)

Paste the contents of `demo-age-key.txt` — the `AGE-SECRET-KEY-1…` line — into
**Paste your age key** and press **Import**. Pasting the whole file works too:
a multi-line blob is treated as a `keys.txt`, so `cat demo-age-key.txt` and ⌘V
is enough.

It is held **in memory for this session only**. Nothing is written to disk, to
the keychain, or to your defaults, and it is gone when you quit. That is the
deliberate trade: paste once per launch, and nothing to leak afterwards.

If you already keep a key at `~/Library/Application Support/sops/age/keys.txt`
(or the `~/.config` path), **Import from this key file** offers to read it. The
label names the file it actually found rather than a guess; where there is more
than one, it asks which; where there is none, it says so instead of offering a
button that would fail. It only ever reads when you press it — never
automatically.

Once a key is imported the status line at the top says so, and a **Forget**
button appears beside it. It clears the key immediately.

### Step 17 · Settings › Updates

![Updates](images/guide-17-updates.png)

One switch, off by default, and off means no request is made at all.

On, it does two things once a day: asks GitHub for the latest sops and age
releases to compare against the versions built in, and looks for a newer version
of the app itself. Both are **version comparisons, not vulnerability scans** —
the app never claims to know whether a version is safe. Nothing downloads or
installs until you press Install.

These are the only network requests the app makes on its own, and they carry no
identifier for you or your Mac. With the switch off you can still check by hand
from the app menu, or from About.

### Step 18 · About

![About](images/guide-18-about.png)

App version and build, the commit it was built from, and the sops and age
versions actually compiled in — the last two are what step 2 compares your CLI
against.

**Check for Updates…** runs a check now, regardless of the switch in step 17.
**Release notes and downloads** opens the releases page in your browser.

The line at the bottom is the app's one-sentence summary of itself: *"This app
decrypts in its own process. Nothing you open, and no key you import, is sent
anywhere."*

---

## Troubleshooting

**A file I can see in Finder is not in the list.** Either it is not sops-
encrypted, or it is sops in a non-YAML format. The footnote at the bottom of the
file list counts the second case.

**"No decryption key configured" on a file I own.** The identity in this session
cannot decrypt that file — the file is encrypted to a recipient you do not hold. Compare the
recipients in the file's `sops` block against your public key.

**The wizard said my sops is out of date.** That is about your *CLI*, not this
app. The app's own engine is the version in About and is unaffected.

**The window opens too large, or will not resize.** It should do neither; both
were real defects, both are fixed, and the minimum is now stated in one place
(`MainWindowMetrics`). If you see it again, that is a bug worth reporting —
include the display resolution.

---

## Regenerating these images

```bash
./Scripts/guide-snapshots.sh
```

Writes `docs/images/guide-*.png`. The catalog is
`Packages/SopsGUIKit/Sources/SnapshotTool/Guide.swift`; adding a step is adding
one `Snapshot` there. Note this is *not* `./Scripts/snapshots.sh`, which writes
the much larger review set to a gitignored directory — the two have opposite
lifecycles and are kept apart on purpose.
