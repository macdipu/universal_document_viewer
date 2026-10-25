# universal_document_viewer

[![pub package](https://img.shields.io/pub/v/universal_document_viewer.svg)](https://pub.dev/packages/universal_document_viewer)
[![CI](https://github.com/macdipu/universal_document_viewer/actions/workflows/ci.yml/badge.svg)](https://github.com/macdipu/universal_document_viewer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Open and read documents in Flutter: **PDF, Word (.docx), Excel (.xlsx), CSV, PowerPoint (.pptx) and plain text**. The document engines are part of the package (PDF runs on PDFium; Word, spreadsheets and slides are read by Dart code written for this package), so there's no web view, no other app and no second document plugin.

Show any file with one widget, or build your own reader UI on one controller API that's the same for every format.

<p>
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/1_home.png" width="200" alt="The example app's home screen">
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/2_pdf.png" width="200" alt="A PDF">
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/3_word.png" width="200" alt="A Word document">
  <img src="https://raw.githubusercontent.com/macdipu/universal_document_viewer/main/screenshots/4_sheet.png" width="200" alt="An Excel sheet">
</p>

## Contents

- [Install](#install)
- [Show a document](#show-a-document)
- [Build your own reader UI](#build-your-own-reader-ui)
- [Where the formats differ](#where-the-formats-differ)
- [Each format](#each-format)
- [Saving the reading position](#saving-the-reading-position)
- [Errors](#errors)
- [Translating and theming](#translating-and-theming)
- [Thumbnails](#thumbnails)
- [Reading a file without showing it](#reading-a-file-without-showing-it)
- [What it reads](#what-it-reads)
- [How it compares](#how-it-compares)
- [Contributing](#contributing)

## Install

```sh
flutter pub add universal_document_viewer
```

It needs Dart 3.11.4 or later and Flutter 3.41 or later, and runs on Android, iOS, macOS, Windows and Linux (not web yet).

**PDFium** comes with it. The package's build hook (`hook/build.dart`) downloads a prebuilt PDFium for the target platform from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) at build time. The release is pinned, and every archive is checked against a pinned SHA-256 before it's used. The first build for each platform needs network access.

## Show a document

```dart
import 'package:universal_document_viewer/universal_document_viewer.dart';

DocumentViewer.file(path)
```

`DocumentViewer` picks the reader by file type and adds a small toolbar: where the reader is, previous and next for pages and slides, zoom, and search. A workbook with several sheets gets a tab per sheet.

```dart
DocumentViewer.file(
  path,
  initialPosition: savedPosition, // reopen where the reader left off
  onPositionChanged: (position) => save(path, position),
  passwordProvider: askForPassword, // Future<String?> Function(); for encrypted PDFs
  errorBuilder: (context, error) => MyErrorView(error),
  showToolbar: true,
)
```

`DocumentViewer.bytes(bytes, format: DocumentFormat.pdf)` shows a document held in memory.

The [example app](example/) shows every format, with sample documents.

## Build your own reader UI

For your own app bar, toolbar or search field, use a format's **controller** and **view**. Every controller extends `DocumentController`, so the code that drives one format drives them all:

| What | `DocumentController` |
|---|---|
| Loading | `loadFile(path)`, `loadBytes(bytes)`, `status` (`idle`, `loading`, `ready`, `failed`), `error` |
| Where the reader is | `location` (current and count of pages, slides, rows, lines, or a percentage), `goTo(number)` |
| Saving the place | `position`, `onPositionChanged` |
| Zoom | `zoom`, `minZoom`, `maxZoom`, `canZoomIn`, `canZoomOut`, `zoomIn()`, `zoomOut()`, `setZoom(zoom)` |
| Search | `search(query)`, `nextMatch()`, `previousMatch()`, `clearSearch()`, `searchState` |

`location` and `searchState` are `ValueListenable`s: listen to just the part you show. Controllers are plain `ChangeNotifier`s with no state-management package and no storage. Dispose a controller you create.

A toolbar written once, for every format:

```dart
class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({super.key, required this.controller});

  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    final strings = DocumentViewerStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Row(children: [
        ValueListenableBuilder(
          valueListenable: controller.location,
          builder: (context, location, _) => Text(strings.location(location)), // "Page 3 of 12"
        ),
        IconButton(icon: const Icon(Icons.zoom_out), onPressed: controller.canZoomOut ? controller.zoomOut : null),
        IconButton(icon: const Icon(Icons.zoom_in), onPressed: controller.canZoomIn ? controller.zoomIn : null),
      ]),
    );
  }
}
```

And a reader screen around it:

```dart
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.path});

  final String path;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final controller = WordController()..loadFile(widget.path);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(onChanged: controller.search, onSubmitted: (_) => controller.nextMatch()),
    ),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => switch (controller.status) {
        DocumentStatus.ready => WordView(controller: controller),
        DocumentStatus.failed => Center(child: Text(DocumentViewerStrings.of(context).loadError(controller.error!))),
        _ => const Center(child: CircularProgressIndicator()),
      },
    ),
    bottomNavigationBar: ReaderToolbar(controller: controller),
  );
}
```

Search counts every occurrence, and the views highlight the current match apart from the others. `DocumentViewerStrings.of(context).searchStatus(controller.searchState.value)` gives "3 of 12", "No matches", or "Searching…" while a PDF is still being searched.

### Where the formats differ

The API is the same everywhere; a few behaviours are worth knowing:

| Format | Notes |
|---|---|
| PDF | Search runs in the background: matches arrive page by page, with `searchState.isSearching` set meanwhile, and a scanned PDF reports no searchable text. Zoom goes from page width (1) to 8. An encrypted file needs `passwordProvider`. |
| Word | In print layout `location` counts pages; reflowed, it's a percentage. The page count is 0 until the view has laid the pages out. Zoom reflows the text when reflowed and scales whole pages in print layout. |
| Spreadsheets | Search counts matching cells (as Excel's Find does) on the sheet on screen; switching sheets ends it. `goTo(n)` scrolls to row n; `goToCell('B3')` takes a reference. |
| PowerPoint | A reading view, not the slide's layout. Zoom enlarges the text; pictures keep their size. |
| Plain text | Zoom scales `PlainTextView.fontSize`. |

`goTo` and `setZoom` can be called as soon as a controller exists: they take effect once the document is loaded and its view has laid it out. `status == DocumentStatus.ready` means the file is parsed, not yet drawn.

## Each format

Import `universal_document_viewer.dart` for everything, or one format's library to keep imports small; each exports the shared `DocumentController` API too.

| Library | Controller | View | Extras |
|---|---|---|---|
| `pdf.dart` | `PdfController` | `PdfView` | password, page layout, fit width, page thumbnails |
| `word.dart` | `WordController` | `WordView` | continuous or print layout, page thumbnails |
| `spreadsheet.dart` | `SpreadsheetController` | `SpreadsheetView` | sheets, go to a cell, freeze the header row |
| `slides.dart` | `SlidesController` | `SlidesView` | previous / next slide, `SlideCard` for previews |
| `plain_text.dart` | `PlainTextController` | `PlainTextView` | line wrap |

### PDF

```dart
final pdf = PdfController(passwordProvider: askForPassword)..loadFile(path);

PdfView(controller: pdf)

pdf.toggleViewMode(); // continuous <-> pages side by side (PdfViewMode)
pdf.fitWidth();
PdfPageThumbnail(controller: pdf, pageNumber: 3);
```

Pages are built only near the viewport, each as a low-resolution image sharpened with tiles when zoomed in. Pinch, double-tap and the mouse wheel zoom. Web links open outside the app (`http`, `https` and `mailto` only); links to pages jump.

### Word

```dart
final word = WordController()..loadFile(path);

WordView(controller: word)

word.viewMode = WordViewMode.paged; // print layout: real pages, headers and footers, page numbers
WordPageThumbnail(controller: word, page: 2);
```

In print layout `location` counts pages; reflowed, it's how far through the document the reader is, in percent. Zoom reflows the text in the continuous layout and scales the pages in print layout.

### Spreadsheets

```dart
final sheet = SpreadsheetController()..loadFile(path); // .xlsx or .csv

SpreadsheetView(controller: sheet)

sheet.switchSheet(1); // names in sheet.sheetNames
sheet.goToCell('Sheet2!B3');
sheet.freezeTopRow = true;
```

The grid builds only the cells on screen, with the file's column widths, row heights, hidden rows and columns, frozen panes, merged cells, number formats, borders, conditional formatting and notes. Tap a cell for its full value, formula and note. Tap a row or column header for its count, sum and average. Search matches cells, as Excel's Find does.

### PowerPoint

```dart
final slides = SlidesController()..loadFile(path);

SlidesView(controller: slides)

slides.nextSlide();
```

Each slide shows its title, text, tables and pictures as a reading view that reflows to the screen; it isn't the slide's original layout. `SlideCard(slide: slides.slides[i], number: i + 1)` draws one slide, for example scaled down as a preview.

### Plain text

```dart
final text = PlainTextController()..loadFile(path);

PlainTextView(controller: text, fontSize: 16)

text.wrap = false; // long lines scroll sideways
```

UTF-8, or UTF-16 with a byte order mark, falling back to Latin-1. Binary files are refused. Zoom scales `fontSize`.

## Saving the reading position

A controller's `position` is a `ReadingPosition`: a plain `Map<String, Object?>` of JSON-safe values. Save it as-is (for example with `jsonEncode`) whenever `onPositionChanged` fires (debouncing is up to you), and pass it back as `initialPosition` to reopen at the same place. The keys are in `PositionKeys`:

| Format | Keys |
|---|---|
| PDF | `pageNumber`, `pageCount`, `viewMode` |
| Word | `scrollOffset`, `viewMode`, `paragraph` (the paragraph at the top) |
| Spreadsheets | `sheetIndex`, `verticalOffset`, `horizontalOffset`, `row`, `column`, `freezeTopRow` |
| PowerPoint | `slideIndex`, `slideCount` |
| Plain text | `scrollOffset`, `line` (the line at the top) |

## Errors

When loading fails, `status` is `DocumentStatus.failed` and `error` says why:
- `tooLarge`: the file, or a ZIP's declared contents, is bigger than the reader will load;
- `corrupted`: damaged or truncated, or an encrypted Office file;
- `passwordRequired`: an encrypted PDF without (or with a wrong) password;
- `unsupported`: not a format the package reads.

`PdfController.errorDetail` has the PDF engine's own exception.

Files from anywhere are expected. Office files are checked before they're parsed: a file over `ZipSafetyGuard.maxFileBytes` isn't read at all, `ZipSafetyGuard` refuses ZIPs with path traversal or oversized declared contents ("zip bombs"), and a part that inflates past its declared size is refused as it's read.

## Translating and theming

Every text the widgets show (messages, labels, tooltips, screen-reader descriptions) comes from `DocumentViewerStrings`, which is English by default. Subclass it and put it above your readers:

```dart
class GermanStrings extends DocumentViewerStrings {
  const GermanStrings();

  @override
  String get noMatches => 'Keine Treffer';

  @override
  String location(DocumentLocation location) => switch (location.unit) {
    DocumentUnit.page => 'Seite ${location.current} von ${location.count}',
    _ => super.location(location),
  };
}

DocumentViewerStringsScope(strings: const GermanStrings(), child: MyApp())
```

Search highlight colours come from the theme (secondary and tertiary containers). Set your own with the `DocumentViewerTheme` extension:

```dart
ThemeData(extensions: const [
  DocumentViewerTheme(matchBackground: Color(0xFFFFF59D), currentMatchBackground: Color(0xFFFFB74D)),
])
```

## Thumbnails

`DocumentThumbnails.render` draws a file's first page as PNG bytes of a given width (the height follows the page's shape):

```dart
final Uint8List? png = await DocumentThumbnails.render(path, width: 160);
final Uint8List? resumed = await DocumentThumbnails.render(path, width: 160, position: savedPosition);
```

| Format | First page | With a saved position |
|---|---|---|
| PDF | page 1 | the saved page |
| Word | page 1 in print layout | the print-layout page holding the paragraph that was at the top |
| PowerPoint | slide 1 | the saved slide |
| Spreadsheets | the top-left cells of the first visible sheet | the saved sheet, from the saved cell |
| Plain text | the first lines | from the line that was at the top |

It returns null rather than throwing for unsupported, damaged, encrypted or too-large files. Caching is up to you.

## Reading a file without showing it

The engines work on their own, with plain Dart models:
- `DocxReader.read(bytes)` returns a `WordDocument`;
- `XlsxReader.read(bytes)` and `CsvReader.read(text)` return a `Workbook`;
- `PptxParser.parse(bytes)` returns a `PptxPresentation`;
- `PdfiumDocument.openFile(path)` renders pages, extracts text and searches.

`testing.dart` has `buildDocx`, `buildXlsx` and `buildPptx`, which build small documents in memory for your tests.

## What it reads

| Format | |
|---|---|
| **PDF** | Continuous or side-by-side pages, zoom with tiles, search with a check for scanned PDFs without text, links, password-protected files |
| **Word** | Reflowed or print layout with measured pages, headers, footers and page numbers; paragraph and character styles, lists, tables with merged cells, images, links and bookmarks, footnotes and endnotes |
| **Excel, CSV** | Several sheets (hidden ones stay hidden), column widths, row heights, frozen panes, merged cells, fonts, fills, borders, number formats, conditional formatting (colours and data bars), notes, links |
| **PowerPoint** | Titles, paragraphs with indent levels, tables and pictures, per slide |
| **Plain text** | `.txt`, Markdown and other text, shown as plain text |

Legacy binary `.doc`, `.xls` and `.ppt` files aren't supported yet. They're next: `.xls` first, then `.doc` and `.ppt`, each read by the package's own engines like the other formats.

## How it compares

Most Flutter document packages read one format, show files through a web view or a vendor engine, or hand the file to another app.

| Package | Formats | How it shows files | Platforms | Licence |
| --- | --- | --- | --- | --- |
| **universal_document_viewer** | PDF, DOCX, XLSX, CSV, PPTX, text | Its own engines: PDFium for PDF, Dart readers for the rest | Android, iOS, macOS, Windows, Linux | MIT |
| [pdfrx](https://pub.dev/packages/pdfrx) | PDF | PDFium; also edits and combines PDFs | Android, iOS, macOS, Windows, Linux, web | MIT |
| [syncfusion_flutter_pdfviewer](https://pub.dev/packages/syncfusion_flutter_pdfviewer) | PDF | Syncfusion's PDF library | Android, iOS, macOS, Windows, Linux, web | Syncfusion licence |
| [pdfx](https://pub.dev/packages/pdfx) | PDF | Pages rendered as images | Android, iOS, macOS, Windows, web | MIT |
| [flutter_pdfview](https://pub.dev/packages/flutter_pdfview) | PDF | The platform's native PDF view | Android, iOS | MIT |
| [docx_viewer](https://pub.dev/packages/docx_viewer) | DOCX, DOC | Flutter widgets | Android, iOS, macOS, Windows, Linux, web | MIT |
| [microsoft_viewer](https://pub.dev/packages/microsoft_viewer) | DOCX, PPTX, XLSX | Flutter widgets | Android, iOS, macOS, Windows, Linux, web | MIT |
| [power_file_view](https://pub.dev/packages/power_file_view), [flutter_filereader](https://pub.dev/packages/flutter_filereader) | Office, PDF, text | Tencent X5 on Android, WKWebView on iOS | Android, iOS | MIT / not stated |
| [open_filex](https://pub.dev/packages/open_filex) | Any | Opens the file in another app | Android, iOS | BSD-3-Clause |

Formats, platforms and licences are as listed on pub.dev in October 2026.

Another package fits better if you need **web** (pdfrx, Syncfusion), want to **edit, fill or annotate PDFs** (pdfrx, Syncfusion: this package only reads), or need legacy **.doc, .xls or .ppt** files today.

## Contributing

Bug reports with a sample file, fixes and new features are welcome.
- [CONTRIBUTING.md](CONTRIBUTING.md): setup, tests, style, pull requests.
- [doc/architecture.md](doc/architecture.md): how the package is built, and where a change belongs.
- [SECURITY.md](SECURITY.md): report a file that crashes or hangs a parser privately.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Showcase: OpenReader

[OpenReader](https://play.google.com/store/apps/details?id=com.chowdhuryelab.openreader) is a document reader app built on universal_document_viewer.

## Licence

MIT; see [LICENSE](LICENSE). PDFium and other third-party code keep their own licences; see [NOTICE.md](NOTICE.md) and `licenses/`.
