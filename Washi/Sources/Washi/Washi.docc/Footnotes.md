# Presenting Footnotes

Intercept note references, extract their content, and present them without
moving the reader.

## Intercept an internal link

Every resolved in-publication link is offered to
``EPUBReaderViewDelegate/readerView(_:shouldFollowInternalLink:)``. Return
`false` for a note reference, then ask the reader for its content:

```swift
import AppKit
import Washi

@MainActor
final class FootnoteCoordinator: EPUBReaderViewDelegate {
    var presentNote: (EPUBNoteContent, CGRect?) -> Void = { _, _ in }

    func readerView(
        _ view: EPUBReaderView,
        shouldFollowInternalLink link: EPUBInternalLink
    ) -> Bool {
        guard link.isNoteReference else { return true }

        Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            if let note = await view.noteContent(for: link) {
                presentNote(note, link.anchorRect)
            } else {
                view.follow(link)
            }
        }
        return false
    }
}
```

The link's `anchorRect` is expressed in the reader view's coordinate system,
so it can anchor an AppKit popover. For a note in the displayed document,
``EPUBNoteContent`` contains readable text and inner HTML. Cross-document notes
are extracted without WebKit and provide text only. Backlink anchors are
removed in both cases.

``EPUBReaderView/follow(_:)`` deliberately bypasses the delegate callback and
records the current locator in navigation history. It is therefore safe to use
as the fallback after an intercepted link, or when a popover offers an explicit
“Go to note” action.

## Remove note asides from pagination

If notes are always presented outside the page, hide recognized footnote and
endnote asides from the paginated flow:

```swift
var settings = reader.settings
settings.hidesFootnoteAsides = true
reader.settings = settings
```

This setting changes layout. Washi repaginates the current item, and the value
is included in the census metrics key so measurements made with visible notes
are not reused for hidden notes.
