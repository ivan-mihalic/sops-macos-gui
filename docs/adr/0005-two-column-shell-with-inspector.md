# ADR 0005 — A two-column shell: a project tree, a detail pane, and an inspector

**Date:** 2026-09-02
**Status:** Accepted
**Milestone:** M3 (SOPS-39)

## Context

The window was four columns: an outer section sidebar (Projects / Health / About / Settings),
a project list, a file list, and the editor. Each column was justified on its own, and
together they left the thing the user actually came for — a secret's value — with **less than
a third of the window**, on a machine where the whole app is one window. Three of the four
columns were navigation over collections small enough to hold in one: a user has a handful of
projects, and a project has a handful of encrypted files.

Two consequences were not cosmetic:

- **The Access panel described the wrong rule, quietly.** `ProjectAccessView` was a sheet
  raised from the file list, and the file list has no selection — so the panel planned
  against whatever file sorted first alphabetically, and described *that* file's creation
  rule as if it were the project's. A `.sops.yaml` with a production rule and a catch-all
  rule looked like a config with one rule, and the one it showed depended on a filename.
  Nothing on screen said which file the answer was about.
- **A key's name was thrown away.** A `.sops.yaml` that declares its keys under a top-level
  `keys:` list gives each an anchor — `&studio`, `&vps` — and that anchor is the name the
  team already uses. The panel rendered three `age1…` strings instead, and so could not
  answer "what does the vps key unlock?" at all.

## Decision

**Two columns: a tree sidebar, and a detail pane whose editor carries a trailing inspector.**

- **The sidebar is one tree** — projects → files, plus an **Access** row per project, with
  About and Settings pinned at its foot per PROPOSAL §4. Selection is a single value,
  `WorkspaceSelection`, and every switch goes through `WorkspaceSwitchGate.decision`, so
  unsaved-work protection is asked once, in one place, for every destination.
- **The editor is a table with a trailing `.inspector`.** The value column belongs to the
  table; the inspector holds one row's detail. **The inspector's value is gated on the same
  reveal state as the table's** — a second place to read a secret that had its own visibility
  rule would be a hole in the one the table enforces.
- **Access is a project page, not a sheet**, bound to the selected file — or, when nothing is
  selected, to the plan's own target file, stated on the page when it was substituted. It
  names keys by their anchor, lists every creation rule, and flags per-file drift between
  what a file is encrypted for and what its rule declares.
- **An anchored rule is read-only except for adding a named key.** A rule that reaches its
  recipients through YAML aliases cannot be rewritten by this app without reformatting
  someone else's config; adding an existing anchor to it as an alias is the one edit that is
  purely additive, so it is the one edit offered.
- **`targetFile` is a named parameter.** `ProjectRecipientApplier.plan(…targetFile:)` and
  `ProjectAccessModel(…targetFile:)` both take it, and both default it to `nil` — "no file in
  particular", which is the ordinary case for a page reached from the sidebar before any file
  was opened. What changed is that it is now passed and named at every call site rather than
  inferred. The
  alphabetically-first fallback still exists — a plan has to plan against something — but it
  is now a stated substitution (`Plan.targetFileWasSubstituted`) rather than an unnamed one.

## Consequences

- **`FileListView` and `ProjectAccessView` are gone**, along with `SectionSidebarList`, the
  `ProjectSidebar` view and `SecretRowView`. Their `LocalizedKey` cases and catalog entries
  went with them (SOPS-39 task 10) — thirty-two strings, each grep-verified unreferenced
  before removal.
- **Three gates went with them:** `ProjectAccessGate.canOpen` (there is no Project Access
  button to gate; navigating to the page is a selection change, and
  `WorkspaceSwitchGate.decision` asks the unsaved-work question for it) and the two static
  button gates `canUpdateConfig`/`canApplyToFiles`. `ProjectAccessModel.applyToFiles()` still
  refuses on its own behalf, which is where a refusal always mattered — a gate can only stop
  a press, never a call.
- **Some model-level disclosures now render nowhere.** `previousIncompleteRun`,
  `Plan.duplicateFileNameCount` and the widened-scope acknowledgement are still computed and
  still tested; the panel that drew them is gone and the page does not. A project-wide
  re-wrap runs per rule through `RewrapCoordinator`, which never widens a scope across rules
  in the first place — so the acknowledgement guards a path no surface offers today. Recorded
  here rather than deleted, because the refusals are load-bearing for any future caller.
- **Three disclosures were deliberately carried over** rather than allowed to lapse with the
  panel: the registry-quarantine banner (SOPS-33), the "commit `.sops.yaml`" sentence, and
  the confirmation before a config write. All three render on `ProjectAccessPage`.
- **Writing `.sops.yaml` is confirmed on the page, not written on one click.** The panel
  raised a `confirmationDialog` before rewriting the config, and it carried two things the
  page cannot say anywhere else: the file is re-emitted whole, so blank lines, a leading
  `---` and the alignment inside `creation_rules` can shift; and dropping a recipient from a
  creation rule revokes nothing, because every file already on disk still decrypts for them
  until it is re-wrapped. Task 10 deleted both with the panel and the page wrote on one
  unconfirmed click for three commits — restored in the final review wave as a confirmation
  on the page, which is what the deleted tests
  (`configUpdateConfirmationDisclosesReformatting`,
  `configUpdateRemovalSentenceDisclaimsRevocation`) protected. The removal sentence now
  points at Rewrap rather than at the panel's "Apply to Files", which no longer exists.
- **A project with nothing to organise gets an explanation, not a blank pane.** The page is
  built out of creation rules and encrypted files; a project with neither — no `.sops.yaml`,
  no encrypted file, or a `.sops.yaml` the bridge could not read — drew a title and two notes
  and nothing else. Each of the three now says which one it is, reusing
  `ProjectStartHereView`'s wording and its New File control, and the unreadable-config case
  reads its reason off `Plan.configError` (the inventory's own is `nil` there, because
  `plan()` hands back `AccessInventory.empty` on that path). No new write path: this page
  still writes only `.sops.yaml`, and only through the confirmation above.
- **`NavigationSplitView`'s sidebar slot and `.inspector` do not populate under the headless
  snapshot renderer**, so `ProjectTreeSidebar`, `SecretRowInspector` and the inspector column
  are snapshotted standalone. See CLAUDE.md, "Visual verification".
- **SOPS-37 must be re-verified against this shell.** It was reported against 0.1.15, where
  Project Access accepted a recipient, dropped it and disabled both CTAs. The panel it was
  filed against no longer exists and `targetFile` is now explicit, so the report needs
  re-measuring on the page before it is either closed or re-filed.

## Addendum — SOPS-42 (2026-09-02): the Access page is the only place recipients change

Three of the bullets above are amended by SOPS-42, after Ivan's first live pass over 0.3.0:

- **An anchored rule is editable by adding *and removing* a named key.** `Remove` was missing;
  the Go side gained `RemoveAliasRecipient` (the inverse of `AddAliasRecipient`, refusing a
  literal spelling and the rule's last age recipient) and `AddNamedKey`, which declares a new
  `- &name age1…` under `keys:` (creating the list before `creation_rules` when absent) and
  aliases it into the rule in one text. Both are behind the same fingerprint-guarded atomic
  write as the alias addition; removal is behind a confirmation naming the key and the files.
- **The editor toolbar's Access button is gone.** It was a second writer of a file's
  recipients that knew nothing about the rule governing the file — the exact split this ADR
  set out to end. `RecipientAccessView`/`RecipientAccessModel` are no longer reachable from
  the app; they and their tests are left for a separate cleanup so this change stays
  reviewable. A file no rule governs is listed on the page with a sentence saying a rule has
  to be added by hand and a button that reveals `.sops.yaml`.
- **Rules are headed by the files they govern, not by their `path_regex`.** The pattern is
  what sops matches on, not what a person recognises a file by; it stays as a caption with a
  tooltip. The "Used in" column of the named-keys table lists files the same way. A rule's
  `.sops.yaml` comment is labelled as such, with a quote glyph, so the user's own prose
  (in whatever language they wrote it) is never read as the app's.

## Related

- PROPOSAL.md §4 (window layout) and §5.4 (project access)
- ADR 0002 — `.sops.yaml` is parsed by sops's own parser, which is why a rule this app will
  not rewrite is explained rather than rewritten
- `docs/GUIDE.md` — the walkthrough, and the images it is illustrated with
