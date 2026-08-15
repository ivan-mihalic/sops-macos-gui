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

**Part 5 has no pictures at all**, and that is the same limitation rather than
an oversight. Both access panels start a live scan of the project when they
appear; the renderer takes a single shot and would catch them mid-scan, showing
a spinner and a count of zero. A picture of the wrong moment is worse than no
picture, so that part is written to stand on its own.

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

The app **does not need them** to work, and the step says so: *"Optional. Useful
if you also work with these files outside this app."* It carries its own sops
engine, in process (`docs/adr/0001`). This step is about the *other* tools you
use on the same files — in your own terminal and in CI, against the same files
this app writes — and a `sops` older than the one baked in here may not
understand what it writes.

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

Editing values is not the only thing you can do to an open file. Changing *who
can read it* is Part 5.

---

## Part 4 — Settings and About

### Step 15 · Settings › Health

![Settings](images/guide-15-settings.png)

Reached from the sidebar or with ⌘, — the same pane either way, in the main
window. ⌘, does not open a window of its own; it selects this row. Three tabs:
**Health**, **Key**, **Scanning**. Step 16 is the second; **Scanning** is one
control, the ceiling on how many files a project scan visits before it stops
and says so.

The update switch used to be a fourth tab here. It lives in About now, next to
**Check for Updates…** — see step 17.

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

### Step 17 · About › the update switch

![Updates](images/guide-17-updates.png)

One switch, off by default, and off means no request is made at all. It sits in
**About**, below Check for Updates — checking now and agreeing to check
automatically are the same decision a moment apart.

On, it does two things once a day: asks GitHub for the latest sops and age
releases to compare against the versions built in, and looks for a newer version
of the app itself. Both are **version comparisons, not vulnerability scans** —
the app never claims to know whether a version is safe. Nothing downloads or
installs until you press Install.

These are the only network requests the app makes on its own, and they carry no
identifier for you or your Mac. With the switch off you can still check by hand
— **Check for Updates…**, in About or in the app menu.

### Step 18 · About

![About](images/guide-18-about.png)

App version and build, the commit it was built from, and the sops and age
versions actually compiled in — the last two are what step 2 compares your CLI
against.

**Check for Updates…** runs a check now, regardless of the switch below it —
that switch is step 17, and this is the page it lives on. **Release notes and
downloads** opens the releases page in your browser.

**About** in the app menu comes here too, rather than opening the small panel
macOS gives an app by default. One page, one version string, nothing to drift.

The line at the bottom is the app's one-sentence summary of itself: *"This app
decrypts in its own process. Nothing you open, and no key you import, is sent
anywhere."*

---

## Part 5 — Access: who can read a file

Everything so far has been about the *contents* of a file. This part is about
its *recipients* — the age public keys a file is encrypted to. Add one and that
person, server or laptop can decrypt the file; remove one and, from then on,
they cannot.

There are three separate places this can change, and the app keeps them separate
on purpose, because they mean different things:

| Where | What it changes | What it does **not** change |
|---|---|---|
| **Access** (one open file) | who can decrypt *that file*, from now on | any other file |
| **Update .sops.yaml** (project) | who *new and re-wrapped* files will be encrypted for | any file already on disk |
| **Apply to Files** (project) | who can decrypt every file the rule governs | the rule itself |

None of the three happens as a side effect of anything else. Saving a file never
re-targets it. Each is its own action behind its own confirmation.

### Step 19 · Extending the walkthrough project

The demo project from the top has one key, which makes for a dull recipients
list. Add a second — pretend it belongs to a colleague:

```bash
cd ~/Development/sops-demo-project
age-keygen -o colleague-age-key.txt
grep '^# public key:' colleague-age-key.txt | cut -d' ' -f4    # this is what you paste
echo colleague-age-key.txt >> .gitignore
```

Keep the public key (`age1…`) on the clipboard. You never need the private half
of it for this part — and the app will refuse it if you try, in every field.

### Step 20 · One file

Open `config/production.secrets.yaml` and use **Access** in the toolbar.

What it shows is read from the file's own `sops` metadata, not from
`.sops.yaml` — that is the difference between who *can* read this file and who
*ought* to be able to. A recipient the project has no name for is shown by its
`age1…` key rather than hidden.

Reading the list needs no key at all. *Changing* it does, because the app has to
decrypt the data key with an identity you hold before it can re-wrap it for
someone else.

Additions and removals are staged: they show as **New** and **Losing access**,
and nothing on disk moves until you press **Apply**. Two things the app will not
do:

- **Remove the last recipient.** *"Removing every recipient would leave this
  file unreadable. Keep at least one."* That includes leaving only keys you do
  not hold.
- **Let you apply over unsaved edits.** The Access button is disabled while the
  document is dirty — *"Save your changes before managing access."* Applying
  reloads the file from disk, which would have silently discarded what you
  typed.

Removing someone is confirmed by name, and the confirmation says the part people
forget: *"Rotate the secret values afterwards: anyone removed may still hold an
old copy."* Taking a key out of a file does not un-see what was already read.

### Step 21 · A whole project

**Project Access…** does the same job at the level of a creation rule.

It works out which rule in `.sops.yaml` governs the project's files, shows the
recipients that rule names, and previews **which files** a run would re-wrap —
not merely how many. Where files fall under a *different* rule, it says so and
how many; where it could not identify a governing rule at all, it says the scope
widened to every encrypted file it found rather than quietly applying to more
than you expected.

The two buttons do genuinely different things, and the confirmations spell out
the difference rather than assuming you know it:

- **Update .sops.yaml…** rewrites the rule. Dropping someone here *"takes
  nothing away — every file already on disk still decrypts for them, because
  their key is still in that file's own metadata."*
- **Apply to Files…** is what actually changes access to existing files. Each
  file is reported on its own as **Updated**, **Already correct** or **Failed**,
  and one unreadable file does not stop the rest of the run. **Stop** ends it
  between files, never mid-write.

Only a flat, age-only creation rule is rewritten. Anything else — several key
groups, a rule mixing age with PGP or KMS, shamir thresholds, YAML anchors — is
read-only, and the panel names the shape it found instead of guessing. The app
does not edit a config it does not fully understand.

Two honest warnings the confirmation gives before it rewrites anything: the file
is written out again in full, so blank lines, a leading `---` and the exact
alignment of trailing comments do not survive (every rule, key and comment
does); and if your rules sit flush against `creation_rules:` rather than
indented under it, every line inside it shifts. Expect a larger diff than the
keys you changed.

### Step 22 · Naming recipients

An `age1…` key is not a person. Any recipient row, in either panel, can be given
a **name**, a **type** (Device, Server, Person) and an optional note.

Names live in `.sops-gui/recipients.json` inside the project — a shared,
version-controlled file that holds **no secrets and grants nothing**. Commit it
and your whole team sees the same names. Nothing private-key-shaped is accepted
in any field of it, including the note.

The one thing worth being clear about: **forgetting a name is not revoking
access.**

> The name “Colleague's laptop” will be dropped from this project's directory of
> names, and this recipient will be shown by its age public key again.
>
> Nothing about access changes. This recipient can still decrypt every file it
> can decrypt now. To actually take that away, remove the recipient in the
> Access panel and apply the change.

That is why forgetting a name is not styled as a destructive action — it destroys
nothing. Removing access is a different control, in a different panel, with a
different confirmation.

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

**The Access button is greyed out.** The document has unsaved changes. Applying
access changes reloads the file from disk, so the app makes you save or discard
first rather than throwing away what you typed.

**"This .sops.yaml will not be rewritten."** The governing rule is a shape the
app will not edit — several key groups, age mixed with PGP/KMS/Vault, a shamir
threshold, or YAML anchors. The panel names which one it found. Editing that
file by hand still works; **Apply to Files** still works, because it does not
touch the config.

**I removed someone from `.sops.yaml` and they can still read the files.**
Working as intended, and the confirmation says so: the rule decides who *new and
re-wrapped* files are encrypted for. Existing files still carry that key in
their own metadata. **Apply to Files** is what changes them.

**I forgot a recipient's name and nothing else happened.** Also intended. Names
are labels in `.sops-gui/recipients.json`; they grant nothing. Access lives in
`.sops.yaml` and in each file's metadata.

**One file came back Failed in a project run.** The other files still went
through — a run does not stop at the first problem. The usual causes are a file
your session key cannot decrypt, and a file that changed on disk after the run
read it, which is refused rather than overwritten.

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
