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

Two consequences worth stating, both of them "this container does not populate
offscreen" rather than anything about the views themselves. `NavigationSplitView`'s
own sidebar column comes back blank, so the sidebar below is rendered from
`ProjectTreeSidebar` standing on its own; SwiftUI's `.inspector` column does the
same, so the editor pictures show the table with an empty strip to its right and
the inspector gets a picture of its own (step 14). Both are the types the app
puts in those columns, not mock-ups.

**Part 5 is mostly written to stand on its own**, for the same reason: an access
panel starts a live scan when it appears, and a single shot would catch it
mid-scan — a spinner and a count of zero, which is a picture of the wrong
moment. The one exception is the project-wide **Access** page (step 21), whose
model is loaded before the shot is taken, so that picture is of the page rather
than of its first frame.

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

![Sidebar, nothing selected](images/guide-07-sidebar.png)

One tree, and everything you can navigate to is in it. Projects are the top
level; each expands to its encrypted files and an **Access** row. **About** and
**Settings** sit in their own group at the bottom, the way macOS sidebars
separate secondary destinations.

The window is two columns: this, and whatever the selection is. It was four —
sections, projects, files, editor — which left the value you came to read under
a third of the window (`docs/adr/0005`).

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

### Step 8 · A project

![A project selected](images/guide-08-projects.png)

Projects you have added, each one a row you can expand. Selecting the project
row itself opens its home page — the file count, the scan's own footnotes, and
anything the walk could not get into. **Add Project…** at the bottom opens a
folder chooser — point it at `~/Development/sops-demo-project`.

A project is just a directory the app remembers. It is not copied, not indexed,
and not modified by being added.

Git worktrees of the same repository are grouped together, so a repo with four
checked-out branches is one heading rather than four unrelated rows.

### Step 9 · The files, and Access

![A file selected](images/guide-09-files.png)

Under each project: every sops-encrypted file below its root, by path — YAML,
dotenv, JSON and INI all open the same way. Click one to open it —
`services/worker.secrets.env`, the `.env` file the setup script above wrote,
opens exactly like the two YAML files above it (SOPS-38).

The dot at the right of a file row is its access state, so drift between a file
and the rule that governs it is visible without opening anything. **Access** —
the last row under every project — is where that is explained; it is step 21.

The footnote at the bottom is still doing real work, just for a narrower case
than it used to: a sops file in a shape this app does not recognise at all is
counted there rather than hidden — a file you can see in Finder silently
missing from the list is the worse outcome — even though the demo project
above does not create one to show it.

---

## Part 3 — The editor

### Step 10 · An open file

![Editor](images/guide-10-editor.png)

Decryption happens in process, using the identity you gave the app for this
session. The key never goes through the environment and never reaches a
subprocess (`docs/adr/0001`).

Each row is one leaf of the document, in a table:

| Column | What it is |
|---|---|
| Key | The key path — `database.url`, `feature_flags.0` |
| Value | The value, **masked by default** |
| Type | The YAML type (`string`, `integer`, …) and a padlock meaning encrypted at rest |
| 👁 | Reveal / hide this one row |
| ⧉ | Copy this value to the clipboard without revealing it |

Value is the widest column, which is the whole point of the table: it is what
you came to read.

Values are masked even though the file is already decrypted in memory. The
threat this addresses is the one in the room: a screen share, a colleague behind
you, a recording.

Toolbar, top right: **−** removes the selected row, **+** adds one,
**Inspector** shows or hides the pane on the right, and **Save** writes the file
back. All of them are disabled until they would do something.

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

There is a second version of this screen. If you have ticked **Remember this
key in my Keychain** at some point, then after a relaunch — or after this Mac
sleeps — the app has a key but has not unlocked it, and the file shows *"Your
key is locked — Your age key is in the Keychain. Unlock it to open this file."*
with an **Unlock with Touch ID** button underneath. One press opens the file;
there is nothing to paste and nowhere else to go. The app distinguishes the two
deliberately: telling somebody to import a key they are already holding is the
app failing to know its own state.

### Step 14 · Adding a row

![Add row](images/guide-14-add-row.png)

**+** opens this sheet. Give the new entry a key and a type; where the selection
sits in a list rather than a map, the sheet appends instead of asking for a name.

The new row is marked **New** until saved. Removing a row is **−**, and it too
is a pending change until Save.

#### The inspector

![The row inspector](images/guide-14b-inspector.png)

The **Inspector** button opens a pane on the right for the selected row: its key
path and type, the value in a field big enough to read a connection string in,
and **Apply** / **Revert** / **Remove** for that row alone.

The value here is behind exactly the same reveal as the value in the table — one
👁, one state. A second place to read a secret with a visibility rule of its own
would be a hole in the rule the table enforces, which is why there isn't one.

Editing values is not the only thing you can do to an open file. Changing *who
can read it* is Part 5.

Not every file in the tree is one your key can open. A file whose recipients
don't include you shows a padlock badge in the sidebar; select it anyway and
it opens read-only — "You can't decrypt this file", the raw encrypted contents
underneath, and who *can* decrypt it, so you know whom to ask. There is
nothing to edit here: Save, +, and − all stay disabled.

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

By default it is held **in memory for this session only**. Nothing is written to
disk or to your defaults, and it is gone when you quit.

Tick **Remember this key in my Keychain** before importing and the app also
stores it in your Keychain, on this Mac only, guarded by Touch ID. Then the next
launch does not ask you to paste anything: the status line reads *"Your age key
is in the Keychain"* and an **Unlock with Touch ID** button appears above the
paste field. One touch and the app can decrypt again.

Unlocking happens **once per launch**, not once per file. After that the key
behaves exactly as a pasted one does — it leaves memory when this Mac sleeps and
after the inactivity period in step 16b — except that getting it back costs a
fingerprint rather than another paste. **Remove from Keychain** deletes the
stored copy for good; **Forget** only clears it from memory, and a stored key
comes straight back with Touch ID.

> ⚠️ **If the tick box says the key could not be saved**, that is a known
> possibility rather than something you did wrong: storing into the Keychain
> needs a system permission whose behaviour could not be verified without a
> person at the machine. Your key still works for this session, and everything
> else on this page works as described. Telling us it happened is useful.

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

There is no per-file Access panel any more (SOPS-42). The inspector's
no-selection state still *shows* who the open file is wrapped for — read from the
file's own `sops` metadata — but changing it happens in one place, the
project's **Access** page, because that is the only place that also knows which
`.sops.yaml` rule the file falls under. Two things the app will still not do
there:

- **Leave a rule with no recipient.** Removing the last named key from a rule is
  refused before the file is touched.
- **Pretend a config edit re-encrypts anything.** Changing `.sops.yaml` changes
  who *new* files are wrapped for; the files already on disk drift, the banner
  says so, and **Rewrap** is the action that closes it. Anyone removed may still
  hold an old copy — rotate the values afterwards.

### Step 21 · A whole project

![The Access page](images/guide-19-access.png)

**Access** — the last row under every project in the sidebar — is a page, not a
sheet, and it answers the three questions the per-file panel cannot.

**What are the keys called?** A `.sops.yaml` that declares its keys under a
top-level `keys:` list gives each one a YAML anchor — `&studio`, `&deploy` — and
that anchor is the name your team already uses. The page shows those names, the
shortened public key beside each, whatever you have named it locally, and the
`path_regex` of every rule that uses it: *what does the deploy key actually
unlock?*, answered without reading the config yourself. The anchor is not a
secret by construction — it sits in a file everyone with the repo can read.

**Which rule governs what?** Every creation rule gets a card, in the order sops
reads them, with the recipients it names and the files it governs. The card for
the rule governing the file you had selected is highlighted. The panel this
replaced described exactly one rule — the one governing whichever file sorted
first alphabetically — so a config with a production rule and a catch-all rule
looked like a config with one rule (`docs/adr/0005`).

**Has anything drifted?** A creation rule says who *new* files are encrypted for.
It says nothing about the files already on disk, and the two answers diverge the
moment anyone edits the config. Each file carries **encrypted for 2 of 3** when
they disagree, each rule a pill saying whether all its files are in sync, and the
banner at the top offers **Rewrap N files…** — the same job `sops updatekeys`
does, per rule, for that rule's own declared recipients. It needs your private
key: re-wrapping means decrypting the data key first.

The banner also says the thing people most often assume the other way round:
*changing `.sops.yaml` re-encrypts nothing by itself.* And a rewrap is not a
revocation — a removed recipient keeps whatever it has already read.

**A rule that goes through anchors is read-only**, and the card says so rather
than guessing: rewriting it would reformat someone else's config. The one edit
offered there is **Add named key…**, which adds an existing anchor to the rule as
an alias — purely additive, and it re-encrypts nothing, which is why the file it
governs turns up in the rewrap banner immediately afterwards. Anything else —
several key groups, age mixed with PGP or KMS, shamir thresholds — is read-only
too, named by the shape found. The app does not edit a config it does not fully
understand.

Files that fall under **no** rule at all are listed under their own heading with
the keys they are wrapped for. Organised by rule, a file no rule governs would
otherwise appear nowhere — and it is precisely the file whose recipients no rule
will ever correct.

### Step 22 · Naming recipients

An `age1…` key is not a person. Any recipient — a row on the per-file panel, or
the **Label** cell on the project's Access page — can be given
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
> file's Access panel and apply the change.

That is why forgetting a name is not styled as a destructive action — it destroys
nothing. Removing access is a different control, in a different panel, with a
different confirmation.

---

## Part 6 — The Setup guide

### Step 23 · Servers, colleagues, and an AI prompt

The **Setup guide** row sits above About in the sidebar (also under the Help
menu). It is PROPOSAL §5 built: how to inject decrypted values with and without
docker compose, how a Linux server and each colleague generate their own age
key, a `.sops.yaml` cookbook, and a prompt to paste into an AI assistant. Every
snippet has a **Copy** button; the app runs none of them for you.

![Setup guide](images/guide-23-setup-guide.png)

The AI prompt is the part worth reading before pasting: it carries the rules of
sops+age with it — the private key never leaves the machine that made it, only
the `age1…` public key is shared, encrypted files and `.sops.yaml` are safe to
commit, a removed recipient keeps what it already read — so an assistant cannot
helpfully suggest otherwise.

## Troubleshooting

**A file I can see in Finder is not under its project in the sidebar.** Either it
is not sops-encrypted, or it is sops in a shape this app does not recognise. The
footnote on the project's home page counts the second case.

**"No decryption key configured" on a file I own.** The identity in this session
cannot decrypt that file — the file is encrypted to a recipient you do not hold. Compare the
recipients in the file's `sops` block against your public key.

**"Your key is locked" every time I open the app.** That is the intended
resting state when your key is in the Keychain: it is unlocked once per launch,
not once per file, and it leaves memory again when this Mac sleeps or after the
inactivity period in Settings › Key. Press **Unlock with Touch ID** and it stays
unlocked for the rest of the session. If you would rather it did not persist at
all, **Remove from Keychain** in Settings › Key deletes the stored copy — after
that the app is back to asking you to paste a key each launch.

**Ticking "Remember this key in my Keychain" says it could not be saved.** Not
something you can fix from the app, and not a sign anything is broken: the key
still works for this session, exactly as a pasted one always has. The Keychain
write is the one part of this feature that could not be verified without a
person at the machine — see [ADR 0006](adr/0006-age-key-in-the-keychain.md),
"What is still unverified".

**The wizard said my sops is out of date.** That is about your *CLI*, not this
app. The app's own engine is the version in About and is unaffected.

**The Access button is greyed out.** The document has unsaved changes. Applying
access changes reloads the file from disk, so the app makes you save or discard
first rather than throwing away what you typed. The same prompt appears if you
click away to the project's **Access** page with edits pending.

**A key on the Access page has no name and I cannot type one in.** The **Name**
column is the anchor from `.sops.yaml` and is read from that file — a key
declared inline has none. The **Label** column next to it is yours: click the
dash and name it.

**"This .sops.yaml will not be rewritten."** The governing rule is a shape the
app will not edit — several key groups, age mixed with PGP/KMS/Vault, a shamir
threshold, or YAML anchors. The rule's card names which one it found. Editing
that file by hand still works, and so does **Rewrap**, because a rewrap brings
files to the rule rather than the other way round. An anchored rule also accepts
**Add named key…**, which is additive and needs no rewrite.

**I removed someone from `.sops.yaml` and they can still read the files.**
Working as intended, and the Access page's banner says so: the rule decides who
*new and re-wrapped* files are encrypted for. Existing files still carry that key
in their own metadata, and the page flags each one as drifted until **Rewrap**
brings it to the rule.

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

⚠️ Both scripts pass `--build-system swiftbuild`, and that is load-bearing:
`swift run`'s default engine copies `Localizable.xcstrings` into the module
bundle uncompiled, so every string resolves to its own raw key and the images
come out reading `access.keys.title` where they should read *Keys*. It renders
perfectly happily — this is a silent failure, not a red one. If a regenerated
image shows dotted key names, that is what happened.
