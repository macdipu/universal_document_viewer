# universal_document_viewer

Open and read documents in Flutter: PDF, Word (.docx), Excel (.xlsx), CSV, PowerPoint (.pptx) and plain text. The document engines are part of the package (PDF runs on PDFium; Word, spreadsheets and slides are read by Dart code written for this package), so there is no other document plugin to add.

Use one widget, `DocumentViewer.file(path)`, that picks the right reader for the file type, or use the controller and view for each format when you want your own app bar, search UI or saving.

<p>
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/1_home.png" width="200" alt="The example app's home screen">
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/2_pdf.png" width="200" alt="A PDF">
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/3_word.png" width="200" alt="A Word document">
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/4_sheet.png" width="200" alt="An Excel sheet">
</p>

## Features

**PDF** (`pdf.dart`)
- Continuous (vertical) or horizontal page layout.
- Pinch, double-tap and mouse-wheel zoom; zoom in/out steps and fit-width from the controller.
- Pages are built only near the viewport, with a low-resolution image per page sharpened by tiles when zoomed in.
- Password-protected PDFs, through a password callback.
- Search across all pages with highlights, and a check for scanned PDFs without a text layer.
- Links: web links open outside the app (`http`, `https`, `mailto` only); links to pages jump.

**Word** (`word.dart`)
- Continuous layout reflowed to the screen, or print layout with measured pages, per-page headers and footers and live page numbers.
- Paragraph and character styles, lists, tables with merged cells, images, links and bookmarks, footnotes and endnotes.
- Parsed in a background isolate; search with highlights; scroll position restore.

**Spreadsheets** (`spreadsheet.dart`)
- Excel `.xlsx` and CSV.
- A lazy 2D grid: only on-screen cells are built.
- The file's column widths and row heights, hidden rows, columns and sheets, frozen panes, merged cells, text formatting and number formats.
- Several sheets, search, zoom, and cell links (web links and links to other cells).
- Select a row or column to see its Count, Sum and Average.

**PowerPoint** (`slides.dart`)
- `.pptx` slides shown as titles, paragraphs, tables and pictures, one slide at a time, with a navigation bar and search.

**Text** (`plain_text.dart`)
- `.txt` and Markdown (`.md`, `.markdown`) shown as plain text, UTF-8 with a Latin-1 fallback.
- Rejects binary files; search with highlights.

**All formats**
- File type detection from the extension, path or MIME type (`DocumentFormat`).
- Office files are checked before parsing (`ZipSafetyGuard`): damaged ZIPs, path traversal and oversized ("zip bomb") contents are refused.
- Reading positions as plain JSON-safe maps, and typed load errors.

Legacy binary `.doc`, `.xls` and `.ppt` files are not supported yet; see [Coming soon](#coming-soon).

## Platforms

Android, iOS, macOS, Windows and Linux. Web is not supported yet.

## How it compares

Most Flutter document packages read one format, show files through a web view or a vendor engine, or hand the file to another app. universal_document_viewer reads six formats inside your app with engines that ship in the package.

| Package | Formats | How it shows files | Platforms | Licence |
| --- | --- | --- | --- | --- |
| **universal_document_viewer** | PDF, DOCX, XLSX, CSV, PPTX, text | Its own engines: PDFium for PDF, Dart readers for Office files and text | Android, iOS, macOS, Windows, Linux | MIT |
| [pdfrx](https://pub.dev/packages/pdfrx) | PDF | PDFium; also edits and combines PDFs | Android, iOS, macOS, Windows, Linux, web | MIT |
| [syncfusion_flutter_pdfviewer](https://pub.dev/packages/syncfusion_flutter_pdfviewer) | PDF | Syncfusion's PDF library | Android, iOS, macOS, Windows, Linux, web | Syncfusion licence (commercial, with a community licence) |
| [pdfx](https://pub.dev/packages/pdfx) | PDF | Pages rendered as images | Android, iOS, macOS, Windows, web | MIT |
| [flutter_pdfview](https://pub.dev/packages/flutter_pdfview) | PDF | The platform's native PDF view | Android, iOS | MIT |
| [docx_viewer](https://pub.dev/packages/docx_viewer) | DOCX, DOC | Flutter widgets | Android, iOS, macOS, Windows, Linux, web | MIT |
| [microsoft_viewer](https://pub.dev/packages/microsoft_viewer) | DOCX, PPTX, XLSX | Flutter widgets | Android, iOS, macOS, Windows, Linux, web | MIT |
| [power_file_view](https://pub.dev/packages/power_file_view), [flutter_filereader](https://pub.dev/packages/flutter_filereader) | Office, PDF, text | Tencent X5 on Android, WKWebView on iOS | Android, iOS | MIT / not stated |
| [open_filex](https://pub.dev/packages/open_filex) | Any | Opens the file in another app | Android, iOS | BSD-3-Clause |

Formats, platforms and licences are as listed on pub.dev in October 2026.

What sets it apart:
- **One package for PDF and Office files.** `DocumentViewer.file(path)` opens any of the six formats; there is no PDF package plus a Word package plus a spreadsheet package to wire together.
- **One contract across formats.** Every reader has a controller with search, a saved reading position as a JSON-safe map, and typed load errors, and `DocumentThumbnails` draws a first-page (or resumed-page) thumbnail for every format.
- **Everything stays in your app.** No web view, no third-party browser engine and no other app. Files are read on the device; nothing is uploaded.
- **Spreadsheets read like the original.** Column widths, frozen panes, merged cells, number formats, borders and conditional formatting, in a lazy grid that builds only the cells on screen.
- **Safe with untrusted files.** Office files are checked before parsing: damaged ZIPs, path traversal and zip bombs are refused.
- **MIT licensed**, with the third-party pieces (PDFium) listed in [`NOTICE.md`](NOTICE.md).

When another package fits better:
- You need **web**: pdfrx and syncfusion_flutter_pdfviewer support it; this package doesn't yet.
- You need to **edit PDFs**, fill forms or annotate: pdfrx and Syncfusion do that; this package reads only.
- You need legacy **.doc, .xls or .ppt** files today: they aren't supported yet (they're [coming](#coming-soon)).

## Installation

```sh
flutter pub add universal_document_viewer
```

To use the latest code from GitHub instead:

```yaml
dependencies:
  universal_document_viewer:
    git:
      url: https://github.com/macdipu/universal_document_viewer.git
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
| `package:universal_document_viewer/pdf.dart` | `PdfController` | `PdfView` |
| `package:universal_document_viewer/word.dart` | `WordController` | `WordView` |
| `package:universal_document_viewer/spreadsheet.dart` | `SpreadsheetController` | `SpreadsheetView` |
| `package:universal_document_viewer/slides.dart` | `SlidesController` | `SlidesView`, `SlideNavigationBar` |
| `package:universal_document_viewer/plain_text.dart` | `PlainTextController` | `PlainTextView` |

### PDF

The view opens the file itself; the controller drives it.

```dart
import 'package:universal_document_viewer/pdf.dart';

final controller = PdfController(onPositionChanged: save);

PdfView(
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
import 'package:universal_document_viewer/word.dart';

final controller = WordController(initialPosition: saved, onPositionChanged: save);
await controller.load(await File(path).readAsBytes());

if (controller.error == null) {
  WordView(controller: controller);
}

controller.toggleViewMode(); // continuous <-> print layout (WordViewMode)
controller.search('agreement'); // matches in controller.searchController
controller.nextMatch();
```

`package:universal_document_viewer/word.dart` has the Word engine on its own: `DocxReader.read(bytes)` returns a `WordDocument` model.

### Spreadsheets

```dart
import 'package:universal_document_viewer/spreadsheet.dart';

final controller = SpreadsheetController(onPositionChanged: save);
await controller.loadXlsx(bytes); // or loadCsv(bytes)

SpreadsheetView(controller: controller);

controller.switchSheet(1); // sheet names in controller.sheetNames
controller.zoomIn();
```

### PowerPoint

```dart
import 'package:universal_document_viewer/slides.dart';

final controller = SlidesController(onPositionChanged: save);
await controller.load(bytes);

Column(children: [
  Expanded(child: SlidesView(controller: controller)),
  SlideNavigationBar(controller: controller),
]);
```

### Text

```dart
import 'package:universal_document_viewer/plain_text.dart';

final controller = PlainTextController(onPositionChanged: save);
controller.load(bytes); // synchronous

PlainTextView(controller: controller, fontSize: 14, wrap: true);
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

The wording is yours. `PdfController.error` holds the PDF engine's exception (`PdfOpenException` or `PdfEngineException`), and `DocumentViewer` maps every failure to a `DocumentLoadError` for its `errorBuilder`: an encrypted PDF it couldn't unlock is `passwordRequired`, any other PDF failure `corrupted`.

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

## Other libraries in this package

- `universal_document_viewer.dart`: `DocumentViewer`, `DocumentThumbnails`, `DocumentFormat`, `ReadingPosition`, `PositionKeys`, `DocumentLoadError`, `ZipSafetyGuard`, `decodeTextBytes`.
- `word.dart`: the Word engine (`DocxReader`, the `WordDocument` model).
- `testing.dart`: `buildDocx`, `buildXlsx` and `buildPptx` build small documents in memory for tests.

## Coming soon

Legacy binary Office files (Office 97-2003), read by the package's own engines like the other formats, in this order:
1. **Excel `.xls`**, in the same sheet reader as `.xlsx`: cells, formula results, fonts, number formats, merged cells and column widths.
2. **Word `.doc`**: text and paragraphs first, then formatting, lists and tables.
3. **PowerPoint `.ppt`**: slide text and pictures, as the `.pptx` reader shows them.

Each one is announced in the changelog when it is released. Password-protected legacy files will report `passwordRequired`.

## Related packages

universal_document_viewer is the first of a family of viewer packages. These are planned and not released yet:
- **universal_image_viewer**: open and view images in Flutter.
- **universal_viewer**: one viewer for documents and images, built on universal_document_viewer and universal_image_viewer.

## Showcase: OpenReader

**OpenReader** is a document reader app built on universal_document_viewer and shows everything it does:
- Google Play: https://play.google.com/store/apps/details?id=com.chowdhuryelab.openreader

The package's own test app is in [`example/`](example): sample documents in every format, every reader, and an on-device integration test.

## Licence

universal_document_viewer is released under the [MIT License](LICENSE).

Third-party code and the PDFium binary keep their own licences; see [`NOTICE.md`](NOTICE.md) and `licenses/`.
