import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

/// A go-to and a zoom asked for before a format's view exists take effect
/// once the view has laid the document out.
void main() {
  Future<void> show(WidgetTester tester, Widget view, {bool Function()? until}) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
    for (var i = 0; i < 100 && !(until?.call() ?? i >= 6); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('plain text', (tester) async {
    final text = PlainTextController();
    addTearDown(text.dispose);
    await text.loadBytes(Uint8List.fromList(utf8.encode([for (var i = 1; i <= 300; i++) 'line $i'].join('\n'))));
    text
      ..goTo(150)
      ..setZoom(1.5);
    await show(tester, PlainTextView(controller: text));
    expect(text.location.value.current, 150);
    expect(text.zoom, 1.5);
  });

  testWidgets('spreadsheet', (tester) async {
    final sheet = SpreadsheetController();
    addTearDown(sheet.dispose);
    await tester.runAsync(
      () => sheet.loadBytes(
        buildXlsx([
          XlsxTestSheet('S', {for (var r = 1; r <= 300; r++) 'A$r': 'row $r'}),
        ]),
      ),
    );
    sheet
      ..goTo(150)
      ..setZoom(1.5);
    await show(tester, SpreadsheetView(controller: sheet));
    expect(sheet.location.value.current, 150);
    expect(sheet.zoom, 1.5);
  });

  testWidgets('Word, reflowed and in print layout', (tester) async {
    final lines = buildDocx([for (var i = 0; i < 400; i++) '<w:p><w:r><w:t>Line $i</w:t></w:r></w:p>'].join());
    final reflowed = WordController();
    addTearDown(reflowed.dispose);
    await tester.runAsync(() => reflowed.loadBytes(lines));
    reflowed
      ..goTo(50)
      ..setZoom(1.5);
    await show(tester, WordView(controller: reflowed));
    expect(reflowed.location.value.current, inInclusiveRange(45, 55));
    expect(reflowed.zoom, 1.5);

    final paged = WordController()..viewMode = WordViewMode.paged;
    addTearDown(paged.dispose);
    await tester.runAsync(() => paged.loadBytes(lines));
    paged.goTo(3);
    await show(tester, WordView(controller: paged));
    expect(paged.location.value, DocumentLocation(current: 3, count: paged.pageCount!, unit: DocumentUnit.page));
  });

  testWidgets('slides, even before loading', (tester) async {
    final slides = SlidesController(parse: (bytes) async => PptxParser.parse(bytes));
    addTearDown(slides.dispose);
    slides.goTo(3);
    await slides.loadBytes(buildPptx([titleShape('One'), titleShape('Two'), titleShape('Three')]));
    await show(tester, SlidesView(controller: slides));
    await tester.pumpAndSettle();
    expect(slides.location.value.current, 3);
    expect(find.text('Three'), findsOneWidget);
  });

  testWidgets('PDF', (tester) async {
    final pdf = PdfController();
    addTearDown(() => tester.runAsync(() async => pdf.dispose()));
    await tester.runAsync(() => pdf.loadFile('test/fixtures/pdf/features.pdf'));
    expect(pdf.pageCount, greaterThan(1));
    pdf
      ..goTo(2)
      ..setZoom(1.5);
    expect(pdf.zoom, 1.5, reason: 'reported before the view exists');
    await show(tester, PdfView(controller: pdf), until: () => pdf.location.value.current == 2);
    await tester.pump();
    expect(pdf.location.value.current, 2);
    expect(pdf.zoom, closeTo(1.5, 0.001));
    await tester.pumpWidget(const SizedBox());
  });
}
