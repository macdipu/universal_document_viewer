import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/markdown/markdown_highlighter.dart';
import 'package:universal_document_viewer/src/markdown/markdown_preview.dart';
import 'package:universal_document_viewer/src/markdown/markdown_source_view.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

void main() {
  group('MarkdownStats', () {
    test('counts words, headings, links and images, ignoring fenced code', () {
      final stats = MarkdownStats.of([
        '# Title',
        '',
        'Hello [link](http://a.b) and ![img](x.png) and <https://c.d>.',
        '```',
        '# not a heading [x](y)',
        '```',
        '## Second',
      ]);
      expect(stats.headings, 2);
      expect(stats.links, 2);
      expect(stats.images, 1);
      expect(stats.lines, 7);
      expect(stats.readingMinutes, 1);
    });

    test('empty and unicode input', () {
      expect(MarkdownStats.of(const []).readingMinutes, 0);
      final s = MarkdownStats.of(['héllo 😀 世界']);
      expect(s.words, 3);
      expect(s.characters, 'héllo 😀 世界'.runes.length);
    });
  });

  group('CodeHighlighter', () {
    const palette = SyntaxPalette(
      keyword: Colors.red,
      string: Colors.green,
      number: Colors.blue,
      comment: Colors.grey,
      type: Colors.orange,
      function: Colors.cyan,
      heading: Colors.purple,
      accent: Colors.pink,
      muted: Colors.black54,
    );

    test('round-trips text and colours tokens', () {
      const code = 'final x = "hi"; // note\nint y = 42;';
      final spans = CodeHighlighter.highlight(code, 'dart', palette);
      expect(spans.map((s) => s.text).join(), code);
      expect(spans.any((s) => s.style?.color == Colors.green), isTrue);
      expect(spans.any((s) => s.style?.color == Colors.grey), isTrue);
      expect(spans.any((s) => s.style?.color == Colors.blue), isTrue);
    });

    test('markdown source lines keep their text', () {
      final lines = ['# Head', '- [x] done **b**', '```dart', 'var a = 1;', '```', '> q', 'plain'];
      final h = MarkdownSourceHighlighter(lines);
      for (var i = 0; i < lines.length; i++) {
        expect(h.spansFor(i, palette).map((s) => s.text).join(), lines[i]);
      }
    });
  });

  group('MarkdownController', () {
    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

    test('CRLF files split into clean lines', () async {
      final c = MarkdownController();
      addTearDown(c.dispose);
      await c.loadBytes(bytes('# T\r\n\r\npara one\r\n\r\npara two'));
      expect(c.lines, ['# T', '', 'para one', '', 'para two']);
      expect(c.stats.headings, 1);
    });

    test('a reload drops the previous search', () async {
      final c = MarkdownController();
      addTearDown(c.dispose);
      await c.loadBytes(bytes('alpha\nbeta'));
      c.search('beta');
      expect(c.matches, hasLength(1));
      await c.loadBytes(bytes('gamma'));
      expect(c.matches, isEmpty);
      expect(c.currentMatch, -1);
      expect(c.searchQuery, isEmpty);
    });

    test('stepping through matches from Preview shows the source', () async {
      final c = MarkdownController();
      addTearDown(c.dispose);
      await c.loadBytes(bytes('beta\nbeta'));
      c.search('beta');
      c.setViewMode(MarkdownViewMode.preview);
      c.nextMatch();
      expect(c.viewMode.value, MarkdownViewMode.code);
    });

    test('each loaded file sets the image folder unless the app chose one', () async {
      final dir = await Directory.systemTemp.createTemp('kit-md-');
      addTearDown(() => dir.delete(recursive: true));
      Future<String> write(String sub) async {
        final file = File('${dir.path}/$sub/readme.md');
        await file.create(recursive: true);
        await file.writeAsString('# x');
        return file.path;
      }

      final a = await write('a');
      final b = await write('b');
      final c = MarkdownController();
      addTearDown(c.dispose);
      await c.loadFile(a);
      expect(c.baseDirectory, endsWith('a'));
      await c.loadFile(b);
      expect(c.baseDirectory, endsWith('b'));
      final fixed = MarkdownController(baseDirectory: '/assets');
      addTearDown(fixed.dispose);
      await fixed.loadFile(b);
      expect(fixed.baseDirectory, '/assets');
    });

    test('knows Markdown extensions, with or without the dot', () {
      expect(MarkdownController.isMarkdownExtension('md'), isTrue);
      expect(MarkdownController.isMarkdownExtension('.MARKDOWN'), isTrue);
      expect(MarkdownController.isMarkdownExtension('txt'), isFalse);
    });

    test('loads like plain text and counts the source', () async {
      final c = MarkdownController();
      addTearDown(c.dispose);
      await c.loadBytes(bytes('# Hi\n\nsome words here'));
      expect(c.error, isNull);
      expect(c.source, '# Hi\n\nsome words here');
      expect(c.stats.headings, 1);
      expect(c.stats.words, 5);
      await c.loadBytes(bytes('one'));
      expect(c.stats.words, 1);
    });

    test('searching from Preview shows the source', () async {
      final c = MarkdownController();
      addTearDown(c.dispose);
      await c.loadBytes(bytes('alpha\nbeta'));
      expect(c.viewMode.value, MarkdownViewMode.preview);
      c.search('beta');
      expect(c.viewMode.value, MarkdownViewMode.code);
      expect(c.matches, hasLength(1));
    });

    test('a saved position round-trips as a ratio', () async {
      final c = MarkdownController(initialPosition: {PositionKeys.scrollOffset: 50 * MarkdownController.unitsPerLine});
      addTearDown(c.dispose);
      await c.loadBytes(bytes(List.generate(100, (i) => 'l$i').join('\n')));
      expect(c.initialRatio, closeTo(0.5, 1e-9));
      expect(c.position[PositionKeys.scrollOffset], 50 * MarkdownController.unitsPerLine);
    });
  });

  testWidgets('Split fits a very short area without throwing', (tester) async {
    final c = MarkdownController(mode: MarkdownViewMode.split);
    addTearDown(c.dispose);
    await c.loadBytes(Uint8List.fromList(utf8.encode('# a\n\nb')));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 400, height: 120, child: MarkdownView(controller: c)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a search from Preview scrolls the source to the first match', (tester) async {
    final c = MarkdownController();
    addTearDown(c.dispose);
    await c.loadBytes(
      Uint8List.fromList(utf8.encode([for (var i = 0; i < 400; i++) i == 350 ? 'needle' : 'line $i'].join('\n'))),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MarkdownView(controller: c)),
      ),
    );
    await tester.pump();
    c.search('needle');
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('needle', findRichText: true), findsOneWidget);
  });

  testWidgets('MarkdownView switches modes, jumps to a line and reports its position', (tester) async {
    ReadingPosition? saved;
    final c = MarkdownController(onPositionChanged: (p) => saved = p);
    addTearDown(c.dispose);
    await c.loadBytes(
      Uint8List.fromList(utf8.encode(List.generate(300, (i) => i == 0 ? '# Title' : 'line ${i + 1}').join('\n\n'))),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MarkdownView(controller: c)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Title', findRichText: true), findsOneWidget);

    c.setViewMode(MarkdownViewMode.split);
    await tester.pump();
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    c.goTo(200);
    await tester.pump();
    await tester.pump();
    expect(saved, isNotNull);
    expect(saved![PositionKeys.line] as int, greaterThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('MarkdownSourceView shows line numbers and highlighted source', (tester) async {
    final scroll = ScrollController();
    final search = PlainTextController();
    addTearDown(scroll.dispose);
    addTearDown(search.dispose);
    final lines = List.generate(200, (i) => i == 0 ? '# Title' : 'line ${i + 1} with **bold**');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownSourceView(lines: lines, search: search, fontSize: 14, controller: scroll),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('Title', findRichText: true), findsOneWidget);
    scroll.jumpTo(1000);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('MarkdownPreview renders rich content and survives malformed input', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    const source = '''
# Heading

Paragraph with **bold**, *em*, `code` and [a link](https://example.com).

- [x] done
- [ ] todo
  - nested

> quote

| a | b |
|---|---|
| 1 | 2 |

![missing](nope/missing.png)

```dart
final x = 1;
```

[unclosed](  **bold
''';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(lines: source.split('\n'), baseDirectory: null, fontSize: 16, controller: controller),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Heading', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsWidgets);
  });
}
