import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

void main() {
  String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('the base contract', () {
    test('a controller with no view has no selection and copies nothing', () async {
      final controller = PlainTextController();
      addTearDown(controller.dispose);
      expect(controller.hasSelection.value, isFalse);
      expect(controller.selectedText(), isNull);
      expect(await controller.copySelection(), isFalse);
      controller.clearSelection();
      controller.selectAll();
      expect(clipboard, isNull);
    });

    test('allText is empty before a document loads', () async {
      final controller = PlainTextController();
      addTearDown(controller.dispose);
      expect(await controller.allText(), isEmpty);
      expect(await controller.copyAllText(), isFalse);
    });
  });

  group('plain text', () {
    testWidgets('select all reports the text, copy puts it on the clipboard, clear empties it', (tester) async {
      final controller = PlainTextController();
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.loadBytes(Uint8List.fromList(utf8.encode('first line\nsecond line'))));
      await tester.pumpWidget(app(PlainTextView(controller: controller)));
      await tester.pump();

      controller.selectAll();
      await tester.pump();
      expect(controller.hasSelection.value, isTrue);
      expect(controller.selectedText(), contains('first line'));
      expect(controller.selectedText(), contains('second line'));

      expect(await controller.copySelection(), isTrue);
      expect(clipboard, controller.selectedText());

      controller.clearSelection();
      await tester.pump();
      expect(controller.hasSelection.value, isFalse);
      expect(controller.selectedText(), isNull);
    });

    testWidgets('copyAllText copies every line even with nothing selected', (tester) async {
      final controller = PlainTextController();
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.loadBytes(Uint8List.fromList(utf8.encode('a\nb\nc'))));
      expect(await controller.allText(), 'a\nb\nc');
      expect(await controller.copyAllText(), isTrue);
      expect(clipboard, 'a\nb\nc');
    });

    testWidgets('closing the view drops the selection', (tester) async {
      final controller = PlainTextController();
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.loadBytes(Uint8List.fromList(utf8.encode('hello world'))));
      await tester.pumpWidget(app(PlainTextView(controller: controller)));
      await tester.pump();
      controller.selectAll();
      await tester.pump();
      expect(controller.hasSelection.value, isTrue);

      await tester.pumpWidget(app(const SizedBox()));
      expect(controller.hasSelection.value, isFalse);
    });
  });

  group('word', () {
    testWidgets('select all and allText give the paragraphs', (tester) async {
      final controller = WordController();
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.loadBytes(
          buildDocx('<w:p><w:r><w:t>Alpha paragraph</w:t></w:r></w:p><w:p><w:r><w:t>Beta paragraph</w:t></w:r></w:p>'),
        ),
      );
      await tester.pumpWidget(app(WordView(controller: controller)));
      await tester.pump();

      controller.selectAll();
      await tester.pump();
      expect(controller.hasSelection.value, isTrue);
      expect(controller.selectedText(), contains('Alpha paragraph'));
      expect(controller.selectedText(), contains('Beta paragraph'));
      expect(await controller.allText(), 'Alpha paragraph\nBeta paragraph');
    });
  });

  group('slides', () {
    testWidgets('select all selects the shown slide; allText gives the whole deck', (tester) async {
      final controller = SlidesController(parse: (b) async => PptxParser.parse(b));
      addTearDown(controller.dispose);
      await controller.loadBytes(
        buildPptx([
          titleShape('Welcome') + bodyShape([('Hello team', 0)]),
          titleShape('Budget'),
        ]),
      );
      await tester.pumpWidget(app(SlidesView(controller: controller)));
      await tester.pump();

      controller.selectAll();
      await tester.pump();
      expect(controller.selectedText(), allOf(contains('Welcome'), contains('Hello team')));
      expect(controller.selectedText(), isNot(contains('Budget')));
      expect(await controller.allText(), allOf(contains('Hello team'), contains('Budget')));
    });
  });

  group('spreadsheet', () {
    test('keeps its own selectedText and reports hasSelection', () async {
      final controller = SpreadsheetController();
      addTearDown(controller.dispose);
      await controller.loadBytes(
        buildXlsx([
          const XlsxTestSheet('Sheet1', {'A1': 'a', 'B1': 'b', 'A2': 'c', 'B2': 'd'}),
        ]),
      );
      expect(controller.hasSelection.value, isFalse);
      controller.selectAll();
      expect(controller.hasSelection.value, isTrue);
      expect(controller.selectedText(), 'a\tb\nc\td');
      expect(await controller.copySelection(), isTrue);
      expect(clipboard, 'a\tb\nc\td');
      controller.clearSelection();
      expect(controller.hasSelection.value, isFalse);
    });
  });
}
