# Changelog

## 0.1.4

Desktop PDF reading.

- **`PdfView(showScrollbar: true)`**: a draggable vertical scrollbar in its own gutter at the right edge, following the view's position and size; click the track to jump. Off by default, meant for mouse-driven desktops. Only applies to the vertical (continuous) layout.
- **Touchpad scrolling no longer zooms the PDF on Windows, Linux and macOS.** A precision touchpad reports a two-finger scroll as a pan-zoom gesture with a little scale noise, and `InteractiveViewer` reads any scale other than 1 as a pinch, so a plain scroll also zoomed. On those platforms its own scale is now off and a deliberate trackpad pinch (a scale change past 6%) still zooms. Ctrl + wheel, double-click and the controller's zoom are unchanged. Touch pinch on Android and iOS is unchanged; a touch screen on a desktop OS no longer pinches in `PdfView`.

## Unreleased (0.2.0)

0.2.0 gives every format the same API and makes the package cleaner to use and to contribute to. It breaks 0.1 code; the tables below say what to change.

### One controller contract: `DocumentController`

Every format's controller extends `DocumentController`, so one toolbar, search bar and position display serve them all:

- **loading:** `loadFile(path)`, `loadBytes(bytes)`, `status` (`DocumentStatus.idle`, `loading`, `ready`, `failed`), `error` (`DocumentLoadError`);
- **where the reader is:** `location` (a `ValueListenable<DocumentLocation>`: current, count and unit, which is page, slide, row, line or percent), `goTo(number)`, and `position` / `onPositionChanged` to save and restore it;
- **zoom:** `zoom`, `minZoom`, `maxZoom`, `canZoomIn`, `canZoomOut`, `zoomIn()`, `zoomOut()`, `setZoom(zoom)`;
- **search:** `search(query)`, `nextMatch()`, `previousMatch()`, `clearSearch()`, and `searchState` (a `ValueListenable<DocumentSearchState>`: query, match count, current match). Search now counts **occurrences** in every format (spreadsheets count matching cells, as Excel's Find does), and the current match is highlighted apart from the others.

### Breaking: names

Every format now has a `<Format>Controller` and a `<Format>View`, and each library is named for its format. `universal_document_viewer.dart` exports everything, so one import is enough; each format library also exports the shared contract.

| 0.1 | 0.2 |
|---|---|
| `import '…/docx.dart'` or `'…/word.dart'` | `import '…/word.dart'` |
| `import '…/sheets.dart'` | `import '…/spreadsheet.dart'` |
| `import '…/text.dart'` | `import '…/plain_text.dart'` |
| `PdfDocumentController`, `PdfDocumentView` | `PdfController`, `PdfView` |
| `PdfReaderViewMode` | `PdfViewMode` |
| `WordDocumentController`, `WordDocumentView` | `WordController`, `WordView` |
| `SheetGrid` | `SpreadsheetView` |
| `SlideDeckController`, `SlideDeckView` | `SlidesController`, `SlidesView` |
| `TextDocumentController`, `TextDocumentView` | `PlainTextController`, `PlainTextView` |
| `BorderLine`, `CellBorders` (Word model) | `WordBorderLine`, `WordCellBorders` (the spreadsheet model keeps `BorderLine` and `CellBorders`) |

### Breaking: behaviour and members

| 0.1 | 0.2 |
|---|---|
| `controller.load(bytes)`, `loadXlsx(bytes)`, `loadCsv(bytes)` | `controller.loadBytes(bytes)`, or `controller.loadFile(path)`, which checks the size before reading |
| `PdfView(path: …, passwordProvider: …)` | `PdfController(passwordProvider: …)..loadFile(path)`, then `PdfView(controller: …)` |
| `PdfController.open(path)`, `isReady` | `loadFile(path)`, `status == DocumentStatus.ready` |
| `PdfController.error` (the engine's exception) | `error` is a `DocumentLoadError`; the exception is `errorDetail` |
| `PdfView.errorBuilder: (context, Object error)` | `(context, DocumentLoadError error)` |
| `rejectAsTooLarge()`, `rejectAsCorrupted()` | `markFailed(DocumentLoadError.tooLarge)` (or `.corrupted`) |
| `SpreadsheetController.goTo('B3')` | `goToCell('B3')`; `goTo(row)` scrolls to a row |
| Word `goToPage(n)`, `currentPage`, `progress`, `pageCount.value` | `goTo(n)`, `location.value`, `pageCount` (an `int?`) |
| `SlidesController.matches` (slide indexes), `PlainTextController.matches` (line indexes) | lists of `SlideMatch` and `TextMatch`: one per occurrence |
| static `minZoom`, `maxZoom`, `zoomStep` | instance getters on each controller |
| `PlainTextView(wrap: …, fontSize: 14)` | `PlainTextController.wrap`; `PlainTextView(fontSize: 16)` is the size at zoom 1 |
| `pdfSearchStatusLabel(…)` | `DocumentViewerStrings.of(context).searchStatus(controller.searchState.value)` |
| `SlideNavigationBar`, `showGoToDialog`, the sheet's zoom buttons (`showZoomControls`) | removed from the format views: build them from the controller, or use `DocumentViewer`'s toolbar. The example app has a go-to-cell dialog to copy. |
| `WordSearchController`, `PdfSearchController` (`controller.searchController`) | internal: use `searchState` |

`PositionKeys.zoom` is gone: no reader wrote or read it.

These are no longer exported (they were implementation details): `WordScope`, `WordBlockView`, `WordDocumentLayout`, `WordPage`, `WordPagination`, `SheetGeometry`, `TextLineMetrics`, `showCellDetail`, `SelectionSummary`, `GridSelection`, and `pdf_layout.dart` apart from `PdfViewMode`.

### Added

- `DocumentViewer` has a toolbar: where the reader is, previous and next for pages and slides, zoom, and search with match stepping (`showToolbar: false` hides it). `DocumentViewer.bytes(bytes, format: …)` shows a document held in memory.
- `DocumentViewerStrings` holds every text the widgets show (English by default). Subclass it and provide it with `DocumentViewerStringsScope` to translate or reword.
- `DocumentViewerTheme`, a `ThemeExtension`, sets the search highlight colours.
- PDF: `loadBytes` opens a PDF held in memory.
- Spreadsheets: `SpreadsheetController(format: …)` says whether `loadBytes` gets a workbook or CSV; left null, it tells from the bytes.
- Word: zoom (the text reflows in the continuous layout, and pages scale and pan sideways in print layout), page tracking in print layout, and `WordPageThumbnail` for page previews.
- PowerPoint: zoom.
- For contributors: CONTRIBUTING, a code of conduct, a security policy, issue and pull-request templates, CI (format, analyze, test, pub.dev score), an architecture guide (`doc/architecture.md`), and contract tests that every format's controller passes. The code follows `flutter_lints` and one formatting width.

### Architecture

- Parsers and models all live under `src/engines/` (the PPTX parser moved there; `engines/sheets` is now `engines/spreadsheet`), and the test builders under `src/testing/`. The public libraries and their names are unchanged.
- A `Finalizer` closes a `PdfiumDocument` that's garbage-collected without `close()`.
- `looksLikeBinary` (in `universal_document_viewer.dart`) is the binary-file check the plain-text and CSV readers share; `PlainTextController.looksBinary` forwards to it.
- Tests now check every entry point's exports, the import rules between modules (documented in `doc/architecture.md`), and that XML entities declared in a DTD aren't expanded.

### Fixed

- `goTo` before the document is loaded or its view has laid it out is no longer lost: it takes effect once the view is ready, for every format (it was dropped for plain text, spreadsheets and Word's continuous layout). A PDF zoom set before its view exists is applied the same way, and `zoom` reports it meanwhile.
- A `PdfView` built after its controller had opened the document (as `DocumentViewer` does) showed a spinner forever.
- Giving a `WordView` or `PlainTextView` another controller kept the old document's layout state (Word's mode, zoom and pages; plain text's scroll listener); a `SpreadsheetView` didn't restore the new controller's scroll position.
- A damaged `.xlsx` is reported as damaged instead of opening as a CSV of its bytes; binary content in a `.csv` is refused.

### Changed

- Plain text: more space between lines and wider margins.
- The search status reads "2 of 4" (was "2 of 4 result(s)").

## 0.1.1

- Screenshots on pub.dev and in the README.
- The example app's home screen is a grid of document cards with large thumbnails and format badges, and its sample documents read like real ones (a guide PDF, a quarterly report, a sales workbook).
- README: a "Coming soon" section for legacy `.xls`, `.doc` and `.ppt` files.
- No changes to the package's code.

## 0.1.0

First release.

universal_document_viewer reads every format with its own engines: PDF through its own bindings to PDFium (downloaded at build time from bblanchon/pdfium-binaries, pinned release and SHA-256), and Word, Excel, CSV and PowerPoint with Dart readers written for the package from the file-format specifications.

- **Any file:** `DocumentViewer.file(path)` picks the reader by file type, restores `initialPosition`, reports `onPositionChanged` and takes an `errorBuilder` and a `passwordProvider` for encrypted PDFs.
- **PDF:** `PdfDocumentController` and `PdfDocumentView`. Continuous or horizontal layout, pinch/double-tap/wheel zoom with tiled rendering, password-protected files, search with highlights and a text-layer check, web and page links.
- **Word (.docx):** `WordDocumentController` and `WordDocumentView`. Parsed off the UI isolate; continuous layout or print layout with measured pages, headers, footers and page numbers; styles, lists, tables with merged cells, images, links, footnotes and endnotes; search. The engine on its own is in `word.dart` (`DocxReader`, `WordDocument`).
- **Spreadsheets (.xlsx, CSV):** `SpreadsheetController` and `SheetGrid`, a lazy 2D grid. Column widths and row heights from the file, hidden rows/columns/sheets, frozen panes, merged cells, text and number formatting, links, search, zoom, row/column Count/Sum/Average.
  - Cell borders, conditional formatting and comments, as the author set them up:
    - **Conditional formatting:** comparisons, text matches, blanks, errors, top/bottom N, above/below average, duplicates, colour scales and data bars. Rules that need a formula evaluated are left out.
    - **Comments:** shown as notes, with a corner marker.
  - Tapping a cell shows its formula, as Excel's formula bar does, and its note. A formula filled down a column shows in each cell with its references moved.
  - `SpreadsheetController.goTo` and `showGoToDialog` jump to a cell (`D120`, `Sheet2!B3`) or a sheet by name, and mark the cell.
  - `freezeTopRow` keeps the header row on screen in a sheet whose file froze none. It's saved in the position as `freeze_top_row`.
- **Thumbnails:** `DocumentThumbnails.render(path, width:)` draws the first page of any supported file as a PNG. Given a saved `position:`, it draws the page reading resumes on. The Word and text readers report the paragraph or line at the top (`PositionKeys.paragraph`, `PositionKeys.line`) for this.
- **PowerPoint (.pptx):** `SlideDeckController`, `SlideDeckView` and `SlideNavigationBar`. Titles, paragraphs, tables and pictures; search.
- **Text (.txt, .md):** `TextDocumentController` and `TextDocumentView`. UTF-8 with a Latin-1 fallback, binary-file check, search.
- **Shared:** `DocumentFormat` (from extension, path or MIME type), `ZipSafetyGuard` for Office files (with a file-size ceiling checked before reading, and parts never inflated past their declared size), reading positions as JSON-safe maps (`ReadingPosition`, `PositionKeys`), typed load errors (`DocumentLoadError`), and `testing.dart` builders for in-memory test documents.
- **Platforms:** Android, iOS, macOS, Windows and Linux. Web is not supported yet.
