# Plan: one three-column `NavigationSplitView`

**Status: not started. Needs a decision, because it rewrites the unsaved-changes
guard.**

## Why

Measured in `docs/ui-review-2026-08-10.md`: the window's minimum is **1138 x 189**.
1138 is honest — `HSplitView` will not compress the sidebar plus three panes
below it — and it is the last thing standing between this app and behaving like
a native macOS three-pane app on a small display. Apple's own three-pane apps
use a single `NavigationSplitView` with three columns, which *collapses* columns
as the window narrows instead of refusing to narrow.

Today's shape, after the 0.1.3 flattening:

```
NavigationSplitView
├── sidebar   List: [Projects] [About | Settings]        220
└── detail    switch selection
               ├── .projects  HSplitView: ProjectSidebar | fileList | editor
               ├── .about     AboutView
               └── .settings  SettingsPaneView
```

Four panes wide in the `.projects` case, two of which are sidebars.

## Target

```
NavigationSplitView
├── sidebar   projects, plus About and Settings as a trailing section
├── content   the selected project's encrypted files
└── detail    the editor — or the About / Settings pane
```

The outer "Projects" row disappears: it is a row whose only job is to reveal a
second list of projects, which is the redundancy that produced the fourth pane.

## Why it is not a layout change

Three separate guarded switches exist, each protecting an open dirty document
from being discarded:

| switch | request function | pending state | dialog lives in |
|---|---|---|---|
| section | `AppShell.requestSectionSwitch(to:)` | `pendingSection` | `AppShell` |
| project | `ProjectWorkspaceView.requestProjectSwitch(to:)` | `pendingSwitch` | `ProjectWorkspaceView` |
| file | `ProjectWorkspaceView.requestFileSwitch(to:)` | `pendingSwitch` | `ProjectWorkspaceView` |

Merging the sections list and the project list into one sidebar means one
selection value spanning both, which means the section and project guards become
one code path — and the confirmation dialog has to move, because the two
currently sit in different views.

Six test files cover this today: `WorkspaceSwitchDecisionTests`,
`SectionSwitchEffectTests`, `OuterSidebarSwitchTests`, `RevealedRowTests`,
`CopyFeedbackTests`, `QuitRequestTests`. They are the reason it is tractable at
all, and they are also the reason it must not be rushed: they encode incidents,
not opinions. `AppShell.applying(_:requested:to:)` carries the comment *"Moving
`selection` here is the data loss described above"*, which is not decoration.

## Steps

1. **Selection type.** `enum Destination: Hashable { case project(StoredProject.ID), about, settings }`.
   `Section` stays for About/Settings so the existing tests keep meaning.
2. **One guarded binding** over `Destination`, routing through a single
   `requestDestinationSwitch` that reuses `WorkspaceSwitchDecision` unchanged —
   the *decision* function is already pure and tested; only its callers merge.
3. **Move the confirmation dialog** to `AppShell`, where the merged binding
   lives. The file switch keeps its own, in the content column.
4. **Sidebar** becomes projects + a trailing `SwiftUI.Section` for About and
   Settings (the shape 0.1.3 already introduced).
5. **Content column** = today's `fileListPane`. **Detail** = today's
   `editorPane`, or `AboutView` / `SettingsPaneView`.
6. Re-measure with `Scripts/ui-probe.swift`: the minimum should fall to roughly
   sidebar + content + editor, and columns should collapse rather than the
   window refusing.

## Risk

The failure mode is not a crash. It is a dirty document discarded without a
prompt — the exact defect `applying(_:requested:to:)` was written for, and one
this milestone has already produced three times through different exits (⌘Q,
⌘W, window close). A wrong merge reintroduces it silently, and the tests that
would catch it are the ones being edited in the same change.

Mitigation: change the callers, never `WorkspaceSwitchDecision` itself; keep
every existing test compiling against the new binding rather than rewriting
assertions; add a case per exit before touching the view.

## Not doing it blind

This is recorded rather than executed because it is a rewrite of the guard that
protects unsaved secrets, and the benefit — a smaller minimum window and
collapsing columns — is a real but bounded improvement. That trade belongs to
the person whose secrets they are.
