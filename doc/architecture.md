# Architecture

This guide is for contributors: how a document gets from bytes to the screen, and where a change belongs. Using the package is covered in the [README](../README.md).

## Layers

```
 file / bytes
     │
 ┌───▼─────────────────────────────┐
 │ Safety and format detection     │  lib/src/common/
 │ ZipSafetyGuard, DocumentFormat, │  checks a file before any parser sees it
 │ text decoding                   │
 └───┬─────────────────────────────┘
     │
 ┌───▼─────────────────────────────┐
 │ Engines (parsing, no Flutter)   │  lib/src/engines/
 │ pdfium/      PDFium over ffi    │  produce plain Dart models:
 │ word/        DocxReader         │  WordDocument, Workbook, PptxPresentation,
 │ spreadsheet/ Xlsx/CsvReader     │  PDF pages and text
 │ slides/      PptxParser         │
 │ ooxml/       the OPC package    │
 └───┬─────────────────────────────┘
     │
 ┌───▼─────────────────────────────┐
 │ Controllers (ChangeNotifier)    │  lib/src/<format>/*_controller.dart
 │ load off the UI isolate, keep   │  the app talks to these: position,
 │ position, zoom, search          │  zoom, search, go to
 └───┬─────────────────────────────┘
     │
 ┌───▼─────────────────────────────┐
 │ Views (widgets)                 │  lib/src/<format>/*_view.dart       
 │ draw the document, lazily       │  no toolbars, dialogs or app text
 └───┬─────────────────────────────┘
     │
 ┌───▼─────────────────────────────┐
 │ DocumentViewer, thumbnails      │  lib/src/viewer/, lib/src/thumbnails/
 │ ready-made for any file         │  the only place with built-in UI
 └─────────────────────────────────┘
```

### Engines
Each engine turns bytes into a model and knows nothing about widgets. That keeps it testable with plain `test()`, and it can run in a background isolate.

- **PDF** goes through PDFium (`pdf_engine.dart`, with the native calls on a worker isolate in `pdfium_worker.dart`). The bindings are generated: see CONTRIBUTING.
- **Word, Excel and PowerPoint** are OOXML ZIP packages. `engines/ooxml/opc_package.dart` reads the package's parts and relationships and knows nothing of any one format. The format readers parse the XML into models (`engines/word/word_model.dart`, `engines/spreadsheet/workbook.dart`, the slide model in `engines/slides/pptx_parser.dart`).
- **CSV and text** are decoded by the shared text decoding: a byte order mark if there is one (UTF-8 or UTF-16), otherwise UTF-8, falling back to Latin-1.

### Controllers
A controller owns one open document:
- loading it, with typed failures (`DocumentLoadError`);
- the reading position, reported as a JSON-safe `ReadingPosition` map (see `reader_contract.dart`) and restored from one;
- zoom, search and go to.

Every controller extends `DocumentController` (`lib/src/common/document_controller.dart`), the contract an app can build one toolbar on: `loadFile`/`loadBytes` and `status`, `location` and `goTo`, `zoom`, and `search` with `searchState`. A format adds its own extras on top (PDF's layout, Word's print layout, sheets, slides). The base class keeps the shared state; a format calls its protected `markLoading`/`markReady`/`markFailed`, `updateLocation` and `updateSearch`. Members only the format's own view calls are marked `@internal`.

Controllers are plain `ChangeNotifier`s with no storage and no state-management package. The app decides where positions live.

### Views
A view draws a controller's document and reports scrolling back to it. Views are lazy: Word builds paragraphs (or pages) as they scroll in, sheets build only the cells on screen, and PDF renders pages near the viewport and sharpens them with tiles as you zoom.

A view has no toolbar or dialog of its own; apps build those from the controller. The little text a view does show (an empty sheet, a cell's details, screen-reader labels) comes from `DocumentViewerStrings.of(context)`, so apps can translate it, and search highlights take their colours from `DocumentViewerTheme.of(context)`.

### DocumentViewer and thumbnails
`DocumentViewer.file(path)` picks the reader for a file and adds the small amount of UI a ready-made viewer needs. `DocumentThumbnails` renders the page a saved position resumes on, offscreen, for library screens.

## The source tree

```
lib/
  universal_document_viewer.dart   everything below, in one import
  pdf.dart  word.dart  spreadsheet.dart  slides.dart  plain_text.dart
                                    one format each, plus the shared contract
  testing.dart                      document builders for tests
  src/
    common/        the contract, format detection, positions and errors,
                   strings, theme, text decoding, the ZIP guard
    engines/       parsing and models, no Flutter
      ooxml/         ZIP parts and relationships shared by the Office formats
      pdfium/        the PDFium binding, its worker isolate, PdfiumDocument
      word/  spreadsheet/  slides/
    pdf/  word/  spreadsheet/  slides/  plain_text/
                   each format's controller, view and view-only helpers
    thumbnails/    offscreen rendering, and a renderer per format
    viewer/        DocumentViewer
    testing/       the builders behind testing.dart (never imported by the rest)
```

## Import rules

`test/dependency_rules_test.dart` enforces these:

1. `common/` imports nothing else in the package.
2. An engine imports only other engines and `common/`, and nothing from Flutter. The PDF engine uses `dart:ui` to turn rendered pixels into images: rendering is its job.
3. `engines/ooxml/` imports no format engine.
4. A format module (`pdf/`, `word/`, `spreadsheet/`, `slides/`, `plain_text/`) imports its engine and `common/`, never another format, `viewer/` or `thumbnails/`. Code two formats need goes in `common/` (as `looksLikeBinary` did, for plain text and CSV).
5. Only `engines/pdfium/` uses the generated PDFium bindings.
6. Only `testing.dart` reaches `src/testing/`.

`thumbnails/` and `viewer/` sit on top: they may use every format.

## PDFium lifecycle

- One worker isolate runs every PDFium call. It starts on first use, is shared by all documents and lives as long as the app; PDFium is initialised once per process.
- If the worker fails to start or dies, every waiting and later call fails with `PdfEngineException`. Nothing waits forever.
- A `PdfiumDocument` is a handle to a document held in the worker. `close()` frees it, and closing twice is harmless. Its owners (`PdfController`, the PDF thumbnail renderer) close what they open. A document collected without `close()` is closed by a `Finalizer`, which is a safety net for apps rather than something the package relies on.
- Requests are prioritised (what's on screen first) and can be cancelled before they start. Closing a document drops its queued requests.

## Untrusted files

Documents come from anywhere, so:
- **Size first:** a file over the format's limit is refused before it's read (`DocumentController.maxFileBytes`: 200 MB for Office files, 20 MB for text and CSV).
- **ZIP:** `ZipSafetyGuard` checks an Office file's central directory (entry count, declared uncompressed size, path traversal) before anything is decompressed, and the ZIP reader refuses a part that inflates past its declared size.
- **XML:** `package:xml` decodes only the predefined and numeric entities and never expands entities declared in a DTD, so there's no entity-expansion attack. `test/xml_safety_test.dart` keeps it that way.
- **Isolates:** parsing runs off the UI isolate, so a slow file doesn't freeze the app.
- **Links:** web links open outside the app for `http`, `https` and `mailto` only.

## Where a change goes
| You want to… | Change |
|---|---|
| read more of a file format (a new XML element, a PDF feature) | the engine and its model, then the view that draws it |
| change how something is drawn | the format's view, or the Word paragraph styler / sheet cell painting |
| add something an app controls (zoom, go to, a mode) | the controller, then its view; keep UI out of the view |
| add built-in UI | `DocumentViewer` only |
| show new text in a view | a member on `DocumentViewerStrings`, read with `DocumentViewerStrings.of(context)` |
| share code between two formats | `common/` (never import one format from another) |
| support a new format | a new engine; a controller extending `DocumentController`; a view; a `DocumentFormat` entry; `DocumentViewer`; a thumbnail renderer; a case in `test/document_controller_contract_test.dart` |

## Tests
Engines are tested on bytes: built in memory (`testing.dart`) or from fixtures written by independent tools (`test/fixtures/*/generate.py`). Controllers and views are tested with `testWidgets`. `test/document_controller_contract_test.dart` runs the same contract checks against every format's controller. `test/public_api_test.dart` checks what every entry point exports, and `test/dependency_rules_test.dart` the import rules above. See CONTRIBUTING for how to run them.
