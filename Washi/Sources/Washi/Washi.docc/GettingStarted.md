# Getting Started with Washi

Open an EPUB away from the main actor, display it in an ``EPUBReaderView``,
and preserve its reading position and pagination census between sessions.

## Open and display a publication

`EPUBPublication.open(url:readStrategy:)` performs the CPU-bound
container and XML parsing in a user-initiated detached task. Once it returns,
load the publication into a reader on the main actor:

```swift
import AppKit
import Washi

@MainActor
final class ReaderViewController: NSViewController, EPUBReaderViewDelegate {
    private let reader = EPUBReaderView(frame: .zero)

    var saveLocator: (EPUBLocator) -> Void = { _ in }
    var saveCensus: (EPUBCensusRecord) -> Void = { _ in }

    override func loadView() {
        reader.autoresizingMask = [.width, .height]
        reader.delegate = self
        view = reader
    }

    func open(
        _ url: URL,
        restoring locator: EPUBLocator? = nil,
        census: EPUBCensusRecord? = nil
    ) async throws {
        let publication = try await EPUBPublication.open(url: url)
        reader.load(publication: publication, at: locator)

        if let census {
            _ = reader.importCensus(census)
        }
    }

    func readerView(
        _ view: EPUBReaderView,
        didMoveTo locator: EPUBLocator,
        pageInItem: Int,
        pageCountInItem: Int
    ) {
        saveLocator(locator)
    }

    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        if let census = view.exportCensus() {
            saveCensus(census)
        }
    }
}
```

`EPUBLocator` is `Codable`, so a host can persist the value received
by the delegate and pass it back through the `at` parameter on the next open.
When an identifier is available, the publication resolves the locator's
`idref` before its numerical spine index, which makes restoration resilient to
reading-order changes between editions.

## Reuse a pagination census

The reader measures every reading-order item using the same layout inputs as
the visible page. Until this work finishes, `pageCensus` and
`censusTotalPages` are `nil`. After the delegate reports an update,
`exportCensus()` returns a Codable ``EPUBCensusRecord``.

Call `importCensus(_:)` after `load(publication:at:)`. The reader accepts a
record only for the same publication edition and current pagination engine.
If its display metrics already match, the page totals become available
immediately; otherwise the accepted record remains cached until those metrics
become active.

For details about cache identity and offscreen resource lifetime, see
<doc:Pagination>.
