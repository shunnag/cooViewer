# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

cooViewer is a macOS comic/image viewer. The active codebase is a **full Swift 6 rewrite**
(macOS 26+, Apple Silicon only) of the original Objective-C app. The legacy sources are
archived under `legacy/` (not built). Most comments and docs are in Japanese.

Two documents drive all work here — consult them before changing behavior:

- `Documentation/legacy-app-analysis.md` — exhaustive behavior spec of the legacy app
  (referenced from code comments as 仕様書 §n). When implementing or fixing a feature,
  match this spec unless `architecture.md` §2.2-2.4 lists it as dropped/changed.
- `Documentation/architecture.md` — rewrite design decisions, feature keep/drop/change
  triage, module layout, milestones.

## Build & test

Submodules are required: `git submodule update --init --recursive`.

```
xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug build
xcodebuild -project CooViewer.xcodeproj -scheme cooViewer -configuration Debug test
```

If `xcode-select` points at CommandLineTools, prefix with `DEVELOPER_DIR=/Applications/Xcode.app`.

- A run-script phase builds XADMaster/UniversalDetector into `Frameworks/` (skipped while
  outputs exist). After updating the submodules, `rm -rf Frameworks` to force a rebuild.
- The pbxproj is hand-written (objectVersion 77, filesystem-synchronized groups): files
  added under `CooViewer/` or `CooViewerTests/` are picked up automatically — do not add
  per-file entries to the pbxproj.
- The app is **arm64-only by design** (`ARCHS = arm64` at project level; the frameworks in
  `Frameworks/` are built arm64-only). Never set `ARCHS = $(ARCHS_STANDARD)` on the target —
  the x86_64 slice then fails to link XADMaster with `Undefined symbol: _OBJC_CLASS_$_XADArchive`.
  Xcode's Signing & Capabilities pane may inject this silently; remove it if it reappears.
- Signing: Debug is ad-hoc (`CODE_SIGN_IDENTITY = "-"`), Release is manual Developer ID
  (team FQTM2788K5) with hardened runtime for notarized distribution.
- Visual verification without screen-recording permission: build Debug, then run
  `cooViewer.app/Contents/MacOS/cooViewer --open <book> --snapshot <out.png>` and Read
  the PNG. Sample book generator: create portrait PNGs in a folder (see git history for
  `makepages.swift`).

## Code conventions

- Swift 6 language mode with strict concurrency; UI is `@MainActor`, sources that wrap
  non-thread-safe libraries (XADArchive, PDFDocument) are actors.
- Comments in Japanese, citing the spec (`仕様書 §n`) or design doc (`設計書 §n`) for any
  behavior that mirrors or deliberately deviates from the legacy app.
- Legacy compatibility is a hard constraint for persisted data: UserDefaults domain
  `jp.coo.cooViewer`, binding array schema (`KeyArray*`/`MouseArray*`), BookSettings/
  RecentItems/LastPages shapes, 0-based vs 1-based page numbers (§13.2). Never change
  these without updating the migration mapping (§13.5).
- Every logic-level module (sources, sorting, layout, bindings, persistence) has XCTest
  coverage in `CooViewerTests/`; keep it that way for new logic.

## Architecture (new app)

- `CooViewer/Core/Source/` — `BookSource` protocol + `FolderSource` (immutable, parallel),
  `ArchiveSource` (actor over XADMaster; filename encoding auto-detection comes from
  XADMaster+UniversalDetector), `PDFSource` (actor over PDFKit, point-size rendering).
- `CooViewer/Core/Book/` — `Book` (@MainActor: sorted entries, current index, spread
  pairing per §4.2, prefetch), `PageLayout`/`PageMarks` (spread decision, legacy "N"/"N-M"
  mark strings), `ReadMode`.
- `CooViewer/Input/` — `ReaderAction` (typed action catalog + legacy number maps),
  `BindingConfiguration` (legacy-compatible 6 arrays, resolution order §5.3, switchAction
  §5.4). Dispatch lives in `ReaderWindowController+Input.swift`.
- `CooViewer/UI/Reader/` — `ReaderWindowController` (+Input/+Library extensions: open
  flow, actions, persistence hooks), `ReaderView` (CALayer-based 1-2 page rendering, fit
  modes, rotation, internal scroll with edge detection), `PageBarView`.
- `CooViewer/Persistence/` — `SettingsStore` (typed accessors over legacy keys),
  `BookHistoryStore` (BookSettings/RecentItems/LastPages, URL bookmarks instead of alias).
- `Scripts/build-frameworks.sh` — nested xcodebuild for the XADMaster submodule.

## Licensing constraints

XADMaster and UniversalDetector are LGPL 2.1: keep them dynamically linked (embedded
frameworks), keep the About-panel XAD credit (`Credits.rtf`), keep license files.
