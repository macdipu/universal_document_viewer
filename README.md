# universal_document_viewer

Open and read documents in Flutter: PDF, Word (.docx), Excel (.xlsx), CSV, PowerPoint (.pptx) and plain text. The document engines are part of the package (PDF runs on PDFium; Word, spreadsheets and slides are read by Dart code written for this package), so there is no other document plugin to add.

Use one widget, `DocumentViewer.file(path)`, that picks the right reader for the file type, or use the controller and view for each format when you want your own app bar, search UI or saving.

## Features

**PDF** (`pdf.dart`)
- Continuous (vertical) or horizontal page layout.
- Pinch, double-tap and mouse-wheel zoom; zoom in/out steps and fit-width from the controller.
- Pages are built only near the viewport, with a low-resolution image per page sharpened by tiles when zoomed in.
- Password-protected PDFs, through a password callback.
- Search across all pages with highlights, and a check for scanned PDFs without a text layer.
- Links: web links open outside the app (`http`, `https`, `mailto` only); links to pages jump.

**Word** (`docx.dart`)
- Continuous layout reflowed to the screen, or print layout with measured pages, per-page headers and footers and live page numbers.
- Paragraph and character styles, lists, tables with merged cells, images, links and bookmarks, footnotes and endnotes.
- Parsed in a background isolate; search with highlights; scroll position restore.

**Spreadsheets** (`sheets.dart`)
- Excel `.xlsx` and CSV.
- A lazy 2D grid: only on-screen cells are built.
- The file's column widths and row heights, hidden rows, columns and sheets, frozen panes, merged cells, text formatting and number formats.
- Several sheets, search, zoom, and cell links (web links and links to other cells).
- Select a row or column to see its Count, Sum and Average.

**PowerPoint** (`slides.dart`)
- `.pptx` slides shown as titles, paragraphs, tables and pictures, one slide at a time, with a navigation bar and search.

**Text** (`text.dart`)
- `.txt` and Markdown (`.md`, `.markdown`) shown as plain text, UTF-8 with a Latin-1 fallback.
- Rejects binary files; search with highlights.

**All formats**
- File type detection from the extension, path or MIME type (`DocumentFormat`).
- Office files are checked before parsing (`ZipSafetyGuard`): damaged ZIPs, path traversal and oversized ("zip bomb") contents are refused.
- Reading positions as plain JSON-safe maps, and typed load errors.

Legacy binary `.doc`, `.xls` and `.ppt` files are not supported.

## Platforms

Android, iOS, macOS, Windows and Linux. Web is not supported yet.

## Installation

```sh
flutter pub add universal_document_viewer
```

To use the latest code from GitHub instead:

```yaml
dependencies:
  universal_document_viewer:
    git:
      url: https://github.com/chowdhuryelab/universal_document_viewer.git
```

It needs Dart 3.11.4 or later and Flutter 3.41 or later.

### PDFium

The PDF engine needs the PDFium native library. You don't add it yourself: the package's build hook (`hook/build.dart`) downloads a prebuilt PDFium for the target platform from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) at build time. The release is pinned and every archive is checked against a pinned SHA-256 before it is used. The first build for each platform therefore needs network access.

## Quick start

```dart
import 'package:universal_document_viewer/universal_document_viewer.dart';

DocumentViewer.file(
  path,
  initialPosition: savedPosition, // reopen where the reader left off
  onPositionChanged: (position) => save(path, position),
  errorBuilder: (context, error) => Center(child: Text('Cannot open: ${error.name}')),
)
```

`DocumentViewer` picks the reader by file type: PDF, Word, Excel (with sheet tabs), CSV, PowerPoint (with slide navigation) or text. It shows a short English message when a file can't be opened, unless you pass `errorBuilder`. Pass `passwordProvider` to ask for the password of an encrypted PDF; without one it shows `passwordRequired`.

See [`example/`](example/) for a runnable app.

## Per-format readers

Every controller is a plain `ChangeNotifier` (no state-management package). Each takes an `initialPosition`, reports changes through `onPositionChanged`, and has `search`, `clearSearch`, `nextMatch` and `previousMatch`. Dispose controllers you create.

| Import | Controller | View |
|---|---|---|
| `package:universal_document_viewer/pdf.dart` | `PdfDocumentController` | `PdfDocumentView` |
| `package:universal_document_viewer/docx.dart` | `WordDocumentController` | `WordDocumentView` |
| `package:universal_document_viewer/sheets.dart` | `SpreadsheetController` | `SheetGrid` |
| `package:universal_document_viewer/slides.dart` | `SlideDeckController` | `SlideDeckView`, `SlideNavigationBar` |
| `package:universal_document_viewer/text.dart` | `TextDocumentController` | `TextDocumentView` |

### PDF

The view opens the file itself; the controller drives it.

```dart
import 'package:universal_document_viewer/pdf.dart';

final controller = PdfDocumentController(onPositionChanged: save);

PdfDocumentView(
  path: path,
  controller: controller,
  passwordProvider: () => askForPassword(), // Future<String?>; null gives up
);

controller.zoomIn();
controller.zoomOut();
controller.fitWidth();
controller.toggleViewMode(); // continuous <-> horizontal
controller.jumpToPage(10);
controller.search('invoice'); // results in controller.searchController
```

### Word

```dart
import 'package:universal_document_viewer/docx.dart';

final controller = WordDocumentController(initialPosition: saved, onPositionChanged: save);
await controller.load(await File(path).readAsBytes());

if (controller.error == null) {
  WordDocumentView(controller: controller);
}

controller.toggleViewMode(); // continuous <-> print layout (WordViewMode)
controller.search('agreement'); // matches in controller.searchController
controller.nextMatch();
```

`package:universal_document_viewer/word.dart` has the Word engine on its own: `DocxReader.read(bytes)` returns a `WordDocument` model.

### Spreadsheets

```dart
import 'package:universal_document_viewer/sheets.dart';

final controller = SpreadsheetController(onPositionChanged: save);
await controller.loadXlsx(bytes); // or loadCsv(bytes)

SheetGrid(controller: controller);

controller.switchSheet(1); // sheet names in controller.sheetNames
controller.zoomIn();
```

### PowerPoint

```dart
import 'package:universal_document_viewer/slides.dart';

final controller = SlideDeckController(onPositionChanged: save);
await controller.load(bytes);

Column(children: [
  Expanded(child: SlideDeckView(controller: controller)),
  SlideNavigationBar(controller: controller),
]);
```

### Text

```dart
import 'package:universal_document_viewer/text.dart';

final controller = TextDocumentController(onPositionChanged: save);
controller.load(bytes); // synchronous

TextDocumentView(controller: controller, fontSize: 14, wrap: true);
```

## Reading positions

A position is a `ReadingPosition`, a plain `Map<String, Object?>` of JSON-safe values. Store it as-is (for example with `jsonEncode`) and pass it back as `initialPosition` to reopen at the same place. The keys are in `PositionKeys`:

| Reader | Keys |
|---|---|
| PDF | `pageNumber`, `pageCount`, `viewMode` |
| Word | `scrollOffset`, `viewMode`, `paragraph` (the paragraph at the top) |
| Spreadsheets | `sheetIndex`, `verticalOffset`, `horizontalOffset`, `row`, `column`, `freezeTopRow` (the reader froze the header row) |
| PowerPoint | `slideIndex`, `slideCount` |
| Text | `scrollOffset`, `line` (the line at the top) |

Positions are reported as the reader moves; debouncing the saves is up to you.

## Errors

The Word, spreadsheet, PowerPoint and text controllers expose `error` as a `DocumentLoadError`:
- `tooLarge`: the file, or a ZIP's declared contents, is bigger than the reader will load.
- `corrupted`: damaged or truncated, or an encrypted Office file.
- `passwordRequired`: an encrypted PDF without (or with a wrong) password.
- `unsupported`: not a format the kit reads.

The wording is yours. `PdfDocumentController.error` holds the PDF engine's exception (`PdfOpenException` or `PdfEngineException`), and `DocumentViewer` maps every failure to a `DocumentLoadError` for its `errorBuilder`: an encrypted PDF it couldn't unlock is `passwordRequired`, any other PDF failure `corrupted`.

Office files are checked before they're parsed: a file over `ZipSafetyGuard.maxFileBytes` is not read at all, and `ZipSafetyGuard` refuses a ZIP whose declared contents are too large. A part that inflates past the size its ZIP declares is refused as it's read.

## Thumbnails

`DocumentThumbnails.render` draws a file's first page as PNG bytes of a given width (height follows the page's shape). Every format is covered:
- **PDF:** page 1.
- **Word:** page 1 in print layout.
- **PowerPoint:** slide 1.
- **Spreadsheets and CSV:** the top-left cells of the first visible sheet.
- **Text:** the first lines.

```dart
final Uint8List? png = await DocumentThumbnails.render('/path/to/report.docx', width: 160);
```

Pass a saved position to draw where reading left off instead:
- **PDF:** the saved page.
- **Word:** the print-layout page holding the paragraph that was at the top. Past 1,000 blocks into the body, it shows a page starting at that paragraph instead.
- **PowerPoint:** the saved slide.
- **Spreadsheets and CSV:** the saved sheet, from the saved top-left cell.
- **Text:** the lines from the one that was at the top.

```dart
final Uint8List? resumed = await DocumentThumbnails.render(path, width: 160, position: savedPosition);
```

A position that doesn't fit the file, or one saved without these keys, gives the first page.

It returns null rather than throwing for unsupported, damaged, encrypted or too-large files. Caching is up to you; the OpenReader app keeps them on disk.

## Other libraries

- `universal_document_viewer.dart`: `DocumentViewer`, `DocumentThumbnails`, `DocumentFormat`, `ReadingPosition`, `PositionKeys`, `DocumentLoadError`, `ZipSafetyGuard`, `decodeTextBytes`.
- `word.dart`: the Word engine (`DocxReader`, the `WordDocument` model).
- `testing.dart`: `buildDocx`, `buildXlsx` and `buildPptx` build small documents in memory for tests.

## Showcase: OpenReader

**OpenReader** is a document reader app built on universal_document_viewer and shows everything it does:
- Google Play: https://play.google.com/store/apps/details?id=com.chowdhuryelab.openreader

The package's own test app is in [`example/`](example): sample documents in every format, every reader, and an on-device integration test.

## Licence

universal_document_viewer is released under the [MIT License](LICENSE).

Third-party code and the PDFium binary keep their own licences; see [`NOTICE.md`](NOTICE.md) and `licenses/`.
