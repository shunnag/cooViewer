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
  triage, module layout, milestones, and cross-cutting rules (§7 設計指針).

`Documentation/development-guide.md` is the human-oriented how-to (build,
snapshot-CLI verification catalog, release steps, pitfalls) — keep it in sync
when those procedures change.

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
- Release & notarization (procedure verified for 2.0b1): bump `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in the pbxproj, then build with
  `xcodebuild -configuration Release build CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  OTHER_CODE_SIGN_FLAGS="--timestamp"` — a plain Release build FAILS notarization
  (no secure timestamp + leftover `get-task-allow` entitlement). Then:
  `ditto -c -k --keepParent cooViewer.app out.zip` →
  `xcrun notarytool submit out.zip --keychain-profile cooviewer --wait` →
  `xcrun stapler staple cooViewer.app` → re-zip the STAPLED app for distribution →
  verify `spctl -a -vv cooViewer.app` says "Notarized Developer ID". Tag `vX.YbN`
  on master and publish via `gh release create` (beta = `--prerelease`).
- Auto-update (Sparkle 2, since 2.0b3): BEFORE the Release build, run
  `Scripts/sign-sparkle-nested.sh` — it re-signs Sparkle's nested executables
  (Updater.app/Autoupdate/XPC services) with Developer ID + timestamp + hardened
  runtime; without this notarization returns Invalid (Xcode's CodeSignOnCopy only
  re-signs the framework itself). Re-run it whenever `Frameworks/` is recreated.
  After publishing the GitHub release, run
  `Scripts/make-appcast.sh <stapled-zip> <version> <build>` (signs the zip with the
  EdDSA key in the login keychain and inserts an `<item>` into `appcast.xml`), then
  commit & push `appcast.xml` to master — the feed URL is the raw master file.
  The Sparkle framework + `sign_update` tooling are fetched by
  `Scripts/fetch-sparkle.sh` (version + SHA-256 pinned; bump both to upgrade).
  `SUFeedURL`/`SUPublicEDKey` live in `CooViewer/Info.plist`. The asset file name
  must be `cooViewer-<version>.zip` because the appcast URL is derived from it.
- Visual verification without screen-recording permission: build Debug, then run
  `cooViewer.app/Contents/MacOS/cooViewer --open <book> --snapshot <out.png>` and Read
  the PNG. The full flag catalog (thumbnails, bookmark editor, settings window with
  `-SettingsSelectedTab n` / `-SettingsSearchText`, file info, navigation steps) is in
  `Documentation/development-guide.md` §2. Sample book generator: create portrait
  PNGs in a folder (see git history for `makepages.swift`).

## Code conventions

- Swift 6 language mode with strict concurrency; UI is `@MainActor`, sources that wrap
  non-thread-safe libraries (XADArchive, PDFDocument) are actors.
- Comments in Japanese **only** (no English duplicates), citing the spec (`仕様書 §n`)
  or design doc (`設計書 §n`) for any behavior that mirrors or deliberately deviates
  from the legacy app. Prefer explaining *why* (spec, avoided bug, performance)
  over *what*.
- Persisted-data compatibility (updated for 2.0b5): the UserDefaults domain
  `jp.coo.cooViewer` and the binding array schema (`KeyArray*`/`MouseArray*`) remain
  legacy-compatible (§13.2) — never change those without a migration mapping (§13.5).
  Book state (bookmarks, per-book settings, last pages, recents) now lives in the
  **v2 store**: one JSON per book (SHA-256 of the canonical path) plus recents.json
  under `Application Support/jp.coo.cooViewer/BookStates/`. The legacy keys
  (BookSettings/RecentItems/LastPages) are imported ONCE at launch
  (`BookHistoryStore.migrateLegacyDataIfNeeded`, flag `BookStateStoreVersion`) and
  then left frozen for the 1.x app; the new app no longer reads or writes them.
  Bookmark pages are 0-based Ints in v2 (legacy 1-based strings are converted).
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
  §5.4), `MouseGestureRecognizer` (pure value-type state machine for click/drag-gesture/
  drag-scroll classification §5.9), `ActionNames` (display names for key/mouse actions and
  triggers). Dispatch lives in `ReaderWindowController+Input.swift`.
- `CooViewer/UI/Reader/` — `ReaderWindowController` (+Input/+Library/+Thumbnails
  extensions: open flow, actions, persistence hooks, page indicator layout/auto-hide),
  `ReaderView` (CALayer-based 1-2 page rendering, fit modes, rotation, internal scroll
  with edge detection, all-button mouse handling + smart zoom / force click),
  `GestureHUDView` (drag-gesture direction HUD), `PageBarView`. Mouse/gesture binding
  editing lives in `CooViewer/UI/Settings/MouseBindingsPane.swift`.
- `CooViewer/UI/Bookmarks/` — `BookmarkEditorView` (copy-edit sheet, Cancel-safe).
- `CooViewer/Persistence/` — `SettingsStore` (typed accessors over legacy keys),
  `BookHistoryStore` (BookSettings/RecentItems/LastPages, URL bookmarks instead of alias),
  `PasswordVault` (archive/PDF password manager: one Keychain master key + AES-GCM
  encrypted vault file; keys are canonical file paths via `Core/CanonicalPath`).
- `Scripts/build-frameworks.sh` — nested xcodebuild for the XADMaster submodule.

## Licensing constraints

XADMaster and UniversalDetector are LGPL 2.1: keep them dynamically linked (embedded
frameworks), keep the About-panel XAD credit (`Credits.rtf`), keep license files.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
