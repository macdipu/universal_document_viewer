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
 │ Engines (parsing, no Flutter UI)│  lib/src/engines/
 │ pdfium/  PDFium over dart:ffi   │  produce plain Dart models:
 │ word/    DocxReader             │  WordDocument, Workbook, PptxPresentation,
 │ sheets/  XlsxReader, CsvReader  │  PDF pages and text
 │ ooxml/   the shared OPC package │
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
- **Word, Excel and PowerPoint** are OOXML ZIP packages. `opc_package.dart` reads the package's parts and relationships. The format readers parse the XML into models (`word_model.dart`, `workbook.dart`, the slide model in `pptx_parser.dart`).
- **CSV and text** are decoded by the shared text decoding: a byte order mark if there is one (UTF-8 or UTF-16), otherwise UTF-8, falling back to Latin-1.

### Controllers
A controller owns one open document:
- loading it, with typed failures (`DocumentLoadError`);
- the reading position, reported as a JSON-safe `ReadingPosition` map (see `reader_contract.dart`) and restored from one;
- zoom, search and go to.

Controllers are plain `ChangeNotifier`s with no storage and no state-management package. The app decides where positions live.

### Views
A view draws a controller's document and reports scrolling back to it. Views are lazy: Word builds paragraphs (or pages) as they scroll in, sheets build only the cells on screen, and PDF renders pages near the viewport and sharpens them with tiles as you zoom.

A view has no toolbar, dialog or English text of its own. Apps build those from the controller.

### DocumentViewer and thumbnails
`DocumentViewer.file(path)` picks the reader for a file and adds the small amount of UI a ready-made viewer needs. `DocumentThumbnails` renders the page a saved position resumes on, offscreen, for library screens.

## Where a change goes
| You want to… | Change |
|---|---|
| read more of a file format (a new XML element, a PDF feature) | the engine and its model, then the view that draws it |
| change how something is drawn | the format's view, or the Word paragraph styler / sheet cell painting |
| add something an app controls (zoom, go to, a mode) | the controller, then its view; keep UI out of the view |
| add built-in UI | `DocumentViewer` only |
| support a new format | a new engine + controller + view, a `DocumentFormat` entry, `DocumentViewer`, a thumbnail renderer |

## Tests
Engines are tested on bytes: built in memory (`testing.dart`) or from fixtures written by independent tools (`test/fixtures/*/generate.py`). Controllers and views are tested with `testWidgets`. See CONTRIBUTING for how to run them.
