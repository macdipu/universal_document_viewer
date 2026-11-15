# universal_document_viewer examples

Copy-paste starting points. The full example app, with sample documents in every format, is in [`example/lib`](https://github.com/macdipu/universal_document_viewer/tree/main/example/lib).

```sh
flutter pub add universal_document_viewer
```

## 1. Show any document with one widget

`DocumentViewer` picks the reader from the file type (PDF, DOCX, XLSX, CSV, PPTX, text, Markdown) and adds a toolbar with position, zoom and search.

```dart
import 'package:flutter/material.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

void main() => runApp(const MaterialApp(home: ViewerScreen(path: '/path/to/report.pdf')));

class ViewerScreen extends StatelessWidget {
  const ViewerScreen({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(path.split('/').last)),
    body: DocumentViewer.file(
      path,
      // Reopen where the reader left off, and save as they move.
      initialPosition: null,
      onPositionChanged: (position) => debugPrint('save $position'),
      // Only asked for an encrypted PDF.
      passwordProvider: () async => 'secret',
    ),
  );
}
```

A document already in memory: `DocumentViewer.bytes(bytes, format: DocumentFormat.pdf)`.

## 2. Your own reader screen

Every format has a controller and a view. All controllers share `DocumentController`, so one toolbar serves every format.

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
      title: TextField(
        decoration: const InputDecoration(hintText: 'Search'),
        onChanged: controller.search,
        onSubmitted: (_) => controller.nextMatch(),
      ),
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

/// Works for any format: PDF, Word, spreadsheets, slides, text, Markdown.
class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({super.key, required this.controller});

  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    final strings = DocumentViewerStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Row(
        children: [
          const SizedBox(width: 16),
          ValueListenableBuilder(
            valueListenable: controller.location,
            builder: (context, location, _) => Text(strings.location(location)), // "Page 3 of 12"
          ),
          const Spacer(),
          ValueListenableBuilder(
            valueListenable: controller.searchState,
            builder: (context, state, _) => Text(strings.searchStatus(state)), // "2 of 7"
          ),
          IconButton(icon: const Icon(Icons.zoom_out), onPressed: controller.canZoomOut ? controller.zoomOut : null),
          IconButton(icon: const Icon(Icons.zoom_in), onPressed: controller.canZoomIn ? controller.zoomIn : null),
        ],
      ),
    );
  }
}
```

Swap `WordController`/`WordView` for any pair below.

## 3. Each format

```dart
// PDF
final pdf = PdfController(passwordProvider: () async => 'secret')..loadFile(path);
PdfView(controller: pdf);
pdf.toggleViewMode(); // continuous <-> side by side

// Word (.docx)
final word = WordController()..loadFile(path);
WordView(controller: word);
word.viewMode = WordViewMode.paged; // print layout with real pages

// Excel (.xlsx) and CSV
final sheet = SpreadsheetController()..loadFile(path);
SpreadsheetView(controller: sheet);
sheet.goToCell('Sheet2!B3');
sheet.freezeTopRow = true;

// PowerPoint (.pptx)
final slides = SlidesController()..loadFile(path);
SlidesView(controller: slides);
slides.nextSlide();

// Plain text
final text = PlainTextController()..loadFile(path);
PlainTextView(controller: text, fontSize: 16);
text.wrap = false;

// Markdown: rendered preview, highlighted source, or both side by side
final md = MarkdownController()..loadFile(path);
MarkdownView(controller: md, fontSize: 16);
md.setViewMode(MarkdownViewMode.split);
print('${md.stats.words} words, ${md.stats.readingMinutes} min read');
```

## 4. Save and restore the reading position

`position` is a JSON-safe `Map`. Store it however you like and pass it back as `initialPosition`.

```dart
final saved = <String, ReadingPosition>{};

final controller = PdfController(
  initialPosition: saved[path],
  onPositionChanged: (position) => saved[path] = position, // debounce in a real app
)..loadFile(path);

// Persist with jsonEncode(saved), restore with jsonDecode.
```

## 5. Thumbnails

```dart
final Uint8List? png = await DocumentThumbnails.render(path, width: 160);
final Uint8List? resumed = await DocumentThumbnails.render(path, width: 160, position: saved[path]);

if (png != null) Image.memory(png);
```

## 6. Translate and theme

```dart
class GermanStrings extends DocumentViewerStrings {
  const GermanStrings();

  @override
  String get noMatches => 'Keine Treffer';
}

MaterialApp(
  theme: ThemeData(extensions: const [
    DocumentViewerTheme(matchBackground: Color(0xFFFFF59D), currentMatchBackground: Color(0xFFFFB74D)),
  ]),
  builder: (context, child) => DocumentViewerStringsScope(strings: const GermanStrings(), child: child!),
  home: const ViewerScreen(path: '/path/to/report.pdf'),
);
```

## Run the example app

```sh
cd example
flutter run
```

It opens bundled samples in every format with `DocumentViewer` and the per-format readers, saves reading positions, and shows a thumbnail of where each document resumes.
