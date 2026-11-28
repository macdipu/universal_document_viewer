import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

void main() {
  group('Markdown headings', () {
    test('nested by level, with line numbers, skipping fenced code', () {
      final entries = markdownOutline(const [
        '# Title',
        'text',
        '## Part one',
        '```',
        '# not a heading',
        '```',
        '### Deep ###',
        '#hashtag is not a heading',
        '~~~sh',
        '## nor this',
        '~~~',
        '## Part two',
        '#',
      ]);
      expect(entries, const [
        OutlineEntry(title: 'Title', level: 0, target: 1),
        OutlineEntry(title: 'Part one', level: 1, target: 3),
        OutlineEntry(title: 'Deep', level: 2, target: 7),
        OutlineEntry(title: 'Part two', level: 1, target: 12),
      ]);
    });

    test('the controller gives them once loaded, and goToOutlineEntry uses the line number', () async {
      final controller = MarkdownController();
      addTearDown(controller.dispose);
      expect(await controller.outline(), isEmpty);
      await controller.loadBytes(Uint8List.fromList(utf8.encode('# One\n\nbody\n\n## Two\n')));
      final outline = await controller.outline();
      expect(outline.map((e) => e.title), ['One', 'Two']);
      controller.goToOutlineEntry(outline.last); // a line number, like goTo
    });
  });

  group('slides', () {
    test('slides with a title are listed, by slide number', () async {
      final deck = SlidesController(parse: (b) async => PptxParser.parse(b));
      addTearDown(deck.dispose);
      await deck.loadBytes(
        buildPptx([
          titleShape('Welcome'),
          bodyShape([('only body', 0)]),
          titleShape('Budget'),
        ]),
      );
      expect(await deck.outline(), const [
        OutlineEntry(title: 'Welcome', level: 0, target: 1),
        OutlineEntry(title: 'Budget', level: 0, target: 3),
      ]);
    });
  });

  group('word', () {
    String heading(String text, int level) =>
        '<w:p><w:pPr><w:outlineLvl w:val="$level"/></w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
    String body(String text) => '<w:p><w:r><w:t>$text</w:t></w:r></w:p>';

    testWidgets('headings are listed nested, and going to one scrolls to it', (tester) async {
      final controller = WordController();
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.loadBytes(
          buildDocx(
            [
              heading('Introduction', 0),
              for (var i = 0; i < 80; i++) body('Filler paragraph number $i of the document.'),
              heading('Details', 1),
              body('Detail text.'),
              heading('Conclusion', 0),
              for (var i = 0; i < 80; i++) body('More filler $i.'),
            ].join(),
          ),
        ),
      );
      final outline = (await tester.runAsync(controller.outline))!;
      expect(outline.map((e) => (e.title, e.level)), [('Introduction', 0), ('Details', 1), ('Conclusion', 0)]);
      expect(outline.every((e) => e.target != null), isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WordView(controller: controller)),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Conclusion', findRichText: true), findsNothing, reason: 'far below the first screen');

      controller.goToOutlineEntry(outline.last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Conclusion', findRichText: true), findsOneWidget);
    });

    test('a document with no headings has an empty outline', () async {
      final controller = WordController();
      addTearDown(controller.dispose);
      await controller.loadBytes(buildDocx(body('just text')));
      expect(await controller.outline(), isEmpty);
    });
  });

  test('formats with no outline give an empty one', () async {
    final text = PlainTextController();
    addTearDown(text.dispose);
    expect(await text.outline(), isEmpty);
    final sheet = SpreadsheetController();
    addTearDown(sheet.dispose);
    expect(await sheet.outline(), isEmpty);
  });
}
