# Understanding Pagination

Use one set of display metrics for the live reader, whole-book page counts, and
offscreen thumbnails.

## One layout model

``EPUBScreenMetrics`` derives the content size, page gap, spread decision,
gutter, typography, and scripted-content state from a viewport and
``EPUBReaderSettings``. The visible ``EPUBReaderView`` and the offscreen
census use the same setup, while ``EPUBScreenAtlas`` applies the publication's
effective `rendition:spread` preference before measuring or rendering.

The static `EPUBScreenMetrics.paginationVersion` value is embedded in every
metrics key. ``EPUBReaderView/importCensus(_:)`` rejects records from an older
pagination engine. If a host maintains a separate cache index, include the
pagination version in that index or discard its entries when the value changes.

## Persist measured counts

``EPUBCensusRecord`` stores a metrics key, a page count for each reading-order
item, and the publication release identifier.
Use `exportCensus()` only after the reader delegate reports a census update,
and feed the decoded record to `importCensus(_:)` after loading the book.

A deterministic missing or broken reading-order resource contributes one page
and does not prevent the remaining items from being measured. Cancellation,
timeout, or WebContent process termination aborts that measurement instead of
publishing an incomplete record.

## Plan screens outside the reader

An atlas exposes the same per-item page counts for a collection or thumbnail
browser:

```swift
import AppKit
import Washi

@MainActor
func buildPlan(
    for publication: EPUBPublication,
    viewportSize: CGSize,
    settings: EPUBReaderSettings
) async -> (counts: [Int], pagesPerScreen: Int)? {
    let atlas = EPUBScreenAtlas(publication: publication)
    defer { atlas.invalidate() }

    let metrics = EPUBScreenMetrics(
        viewportSize: viewportSize,
        settings: settings
    )
    return await atlas.screenPlan(metrics: metrics)
}
```

Call offscreen rendering work from a task with `.userInitiated` priority or
higher. The atlas's census and thumbnail WebKit instances are released after
20 seconds without a request and recreated lazily. You must still call
``EPUBScreenAtlas/invalidate()`` when discarding an atlas; invalidation cancels
work, tears down invisible windows and WebContent processes, and makes that
atlas permanently unusable.

``EPUBPageRasterizer`` keeps its offscreen resources until
``EPUBPageRasterizer/invalidate()`` is called. A reader view cancels and tears
down its own offscreen census and thumbnail resources when it leaves its
window.
