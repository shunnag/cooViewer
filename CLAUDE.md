# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

cooViewer is a macOS comic/image viewer (Objective-C, Cocoa). This repo is a fork of coo-ona/cooViewer updated to build on macOS Monterey+ (Xcode 14+, Intel and Apple Silicon), with the XADMaster and UniversalDetector dependencies converted to git submodules. README and most code comments/UI strings are in Japanese.

## Build

Submodules are required — after cloning run:

```
git submodule update --init --recursive
```

Build from the CLI:

```
xcodebuild -configuration Deployment [-arch x86_64|arm64]
```

Output lands in `build/Deployment/cooViewer.app`. Omitting `-arch` produces a universal binary. The main configurations are `Deployment` (release) and `Development`; Xcode.app builds use `Development` by default.

A shell-script build phase in the cooViewer target runs `xcodebuild -scheme XADMaster -configuration Release` inside the `XADMaster/` submodule with `CONFIGURATION_BUILD_DIR=../`, so `XADMaster.framework` and `UniversalDetector.framework` are produced at the repo root and linked from there. If linking fails against these frameworks, check that step (and the submodules) first.

There are no tests and no linter.

## Code conventions

- Manual retain/release — ARC is **not** enabled. Follow retain/release/autorelease discipline in any new or edited code.
- Old-style Objective-C throughout: ivars declared in `@interface` blocks in headers, `IBOutlet id` outlets, getter/setter methods instead of `@property`. Match this style.
- `COImageLoader_temp.m` exists at the repo root but is not in the build; the compiled version is `COImageLoader.m`.

## Architecture

Almost everything hangs off a single `Controller` object (an `NSObject` instantiated in the main nib) that acts as app delegate, window/menu controller, page navigator, and cache manager:

- **`Controller.m`** (~114 KB) — book opening, page navigation, image caching/lookahead, two-page composition, bookmarks/recent-items persistence via `NSUserDefaults`, fullscreen/view management. Alias (`AliasHandle`) round-tripping is used to persist file references.
- **`Controller_input.m`** — the `Controller (Input)` category: all key/mouse/scroll-wheel/gesture/Apple Remote input dispatch, mapped through user-configurable binding arrays (`keyArray`, `mouseArray`, per read-mode variants).
- **`COImageLoader`** — abstraction over the current "book". A book can be a folder, zip, rar (any archive XADMaster handles), PDF, or saved search; `mode` distinguishes them. It exposes contents as a sorted index → `NSImage` interface, handles archive passwords, and extracts to a temp dir when needed. Archive access goes through `XADWrapper`/`XADItem` (wrapping the XADMaster framework); PDFs go through `COPDFImage`/`COPDFImageRep`.
- **Display** — `CustomImageView` inside `CustomWindow` renders one or two pages (right-to-left or left-to-right reading modes, composition of facing pages happens in `Controller`). `LoupeView`, `FullImagePanel`/`FullImageView` provide magnification/original-size views.
- **Aux panels** — `ThumbnailController`, `BookmarkController`, `PreferenceController` (each with matching panel/matrix view classes). `PreferenceController.m` is large because every behavior (input bindings, caching, read modes) is user-configurable.
- **Remote control** — `RemoteControl`/`AppleRemote`/`HIDRemoteControlDevice`/`GlobalKeyboardDevice`/`MultiClickRemoteBehavior` are the bundled Remote Control Wrapper library (separate license, `Licence_RemoteControlWrapper.txt`).

## Localization

UI is localized via xibs in `Base.lproj`/`en.lproj`/`ja.lproj`. `localize/` holds `.xcloc` exports; `localize_helper/localize.rb` migrates old-format Japanese translations into `ja.xliff`.
