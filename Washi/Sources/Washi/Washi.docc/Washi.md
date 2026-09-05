# ``Washi``

Build native macOS reading experiences for reflowable and fixed-layout EPUB publications.

## Overview

Washi combines the headless parsing APIs from `WashiCore` with an AppKit and
WebKit rendering layer. Use ``EPUBReaderView`` for an interactive reader,
``EPUBScreenAtlas`` to plan and render a book outside the reader, and
``EPUBPageRasterizer`` for complex fixed-layout pages.

The reader, atlas, and page rasterizer are main-actor isolated. Open
publications asynchronously with `EPUBPublication.open(url:readStrategy:)`
before handing them to a reader or an offscreen renderer.

### Guides

- <doc:GettingStarted>
- <doc:Footnotes>
- <doc:Pagination>

## Topics

### Reading

- ``EPUBReaderView``
- ``EPUBReaderViewDelegate``
- ``EPUBTextSelection``
- ``EPUBTextRangeLanding``
- ``EPUBKeyEvent``
- ``EPUBClickEvent``

### Navigation

Navigation positions and table-of-contents entries use the re-exported
`EPUBLocator` and `EPUBNavItem` types from WashiCore.

- ``EPUBInternalLink``
- ``EPUBNoteContent``

### Settings

- ``EPUBReaderSettings``
- ``EPUBReaderInsets``
- ``EPUBReaderTheme``
- ``EPUBPageTurnStyle``
- ``EPUBColumnMode``
- ``EPUBRGBAColor``
- ``EPUBContextMenuPolicy``

### Accessibility

``EPUBReaderView`` exposes native accessibility metadata and page-change
announcements. Publication-declared accessibility metadata is available as the
re-exported `EPUBAccessibility` type from WashiCore.

### Offscreen Rendering

- ``EPUBScreenAtlas``
- ``EPUBScreenMetrics``
- ``EPUBCensusRecord``
- ``EPUBPageRasterizer``
- ``EPUBSchemeHandler``

### Core Parsing

The re-exported `WashiCore` module provides `EPUBPublication`, `EPUBPackage`,
`EPUBMetadata`, `EPUBNavigation`, `EPUBSearchOptions`, `EPUBSearchHit`,
`MediaOverlay`, and `EPUBEncryptionInfo`. Their symbol documentation is in the
WashiCore catalog.
