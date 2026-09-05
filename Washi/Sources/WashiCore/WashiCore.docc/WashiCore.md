# ``WashiCore``

Parse, inspect, and search EPUB publications without AppKit or WebKit.

## Overview

WashiCore is Washi's headless layer. It opens zipped EPUB files, unpacked EPUB
directories, and in-memory EPUB data; exposes package, navigation,
accessibility, encryption, and media-overlay metadata; resolves resources and
locators; decodes covers; and extracts or searches publication text.

Use ``EPUBPublication/open(url:readStrategy:)`` from UI code so container and
XML parsing runs outside the main actor:

```swift
import WashiCore

let publication = try await EPUBPublication.open(url: epubURL)
print(publication.metadata.mainTitle ?? "Untitled")

for hit in publication.search("paper") {
    print(hit.spineIndex, hit.utf16Range, hit.snippet)
}
```

## Topics

### Opening Publications

- ``EPUBPublication``
- ``EPUBReadStrategy``
- ``EPUBError``
- ``ReadingOrderItem``
- ``EPUBLocator``
- ``FixedLayoutPageInfo``
- ``PageSpreadSlot``

### Package Metadata

- ``EPUBPackage``
- ``EPUBMetadata``
- ``EPUBAccessibility``
- ``EPUBTitle``
- ``EPUBCreator``
- ``EPUBIdentifier``
- ``EPUBCollectionMembership``
- ``EPUBMetaItem``
- ``ManifestItem``
- ``SpineItemRef``
- ``EPUBSpine``

### Rendition and Direction

- ``PageProgressionDirection``
- ``EPUBReadingDirectionSource``
- ``EPUBTextDirection``
- ``RenditionProperties``
- ``RenditionLayout``
- ``RenditionOrientation``
- ``RenditionSpread``
- ``RenditionFlow``

### Navigation and Text

- ``EPUBNavigation``
- ``EPUBNavItem``
- ``EPUBFlatTOCEntry``
- ``EPUBSearchOptions``
- ``EPUBSearchHit``

### Container and Resources

- ``ZipArchive``
- ``ZipEntryInfo``
- ``ZipError``
- ``ContainerPath``
- ``EPUBMediaType``
- ``EPUBEncryptionInfo``
- ``FontDeobfuscator``
- ``MediaOverlay``
