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
- **`targetFile` is explicit.** `ProjectRecipientApplier.plan(…targetFile:)` and
  `ProjectAccessModel(…targetFile:)` take it as a parameter with no default. The
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
- **Two disclosures were deliberately carried over** rather than allowed to lapse with the
  panel: the registry-quarantine banner (SOPS-33) and the "commit `.sops.yaml`" sentence.
  Both now render on `ProjectAccessPage`.
- **`NavigationSplitView`'s sidebar slot and `.inspector` do not populate under the headless
  snapshot renderer**, so `ProjectTreeSidebar`, `SecretRowInspector` and the inspector column
  are snapshotted standalone. See CLAUDE.md, "Visual verification".
- **SOPS-37 must be re-verified against this shell.** It was reported against 0.1.15, where
  Project Access accepted a recipient, dropped it and disabled both CTAs. The panel it was
  filed against no longer exists and `targetFile` is now explicit, so the report needs
  re-measuring on the page before it is either closed or re-filed.

## Related

- PROPOSAL.md §4 (window layout) and §5.4 (project access)
- ADR 0002 — `.sops.yaml` is parsed by sops's own parser, which is why a rule this app will
  not rewrite is explained rather than rewritten
- `docs/GUIDE.md` — the walkthrough, and the images it is illustrated with
