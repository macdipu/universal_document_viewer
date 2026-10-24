import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/docx.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/testing.dart';

void main() {
  Future<WordDocumentController> load(WidgetTester tester, Uint8List bytes) async {
    final controller = WordDocumentController();
    await tester.runAsync(() => controller.load(bytes));
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpView(WidgetTester tester, WordDocumentController controller) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WordDocumentView(controller: controller))));
    await tester.pump();
  }

  bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

  testWidgets('renders the python-docx fixture: text, lists, table, image', (tester) async {
    final controller = await load(tester, File('test/fixtures/word/features.docx').readAsBytesSync());
    expect(controller.error, isNull);
    await pumpView(tester, controller);
    expect(shows('Report header'), isTrue);
    expect(shows('Quarterly Report'), isTrue);
    expect(shows('Visit our site'), isTrue);
    expect(find.text('•'), findsWidgets);
    expect(find.text('2.'), findsOneWidget);
    expect(shows('wide'), isTrue);
    expect(shows('tall'), isTrue);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('search highlights matches and jumps to them', (tester) async {
    final controller = await load(
      tester,
      buildDocx([for (var i = 0; i < 300; i++) '<w:p><w:r><w:t>Line $i${i == 250 ? ' needle' : ''}</w:t></w:r></w:p>'].join()),
    );
    await pumpView(tester, controller);
    expect(shows('Line 250'), isFalse, reason: 'not built yet: the list is lazy');
    controller.search('NEEDLE');
    expect(controller.searchController.matchCount, 1);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(shows('Line 250 needle'), isTrue);
    expect(tester.getTopLeft(find.textContaining('Line 250', findRichText: true)).dy, lessThan(600));
  });

  testWidgets('reports the paragraph at the top once a scroll settles', (tester) async {
    final reported = <ReadingPosition>[];
    final controller = WordDocumentController(onPositionChanged: reported.add);
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.load(buildDocx([for (var i = 0; i < 300; i++) '<w:p><w:r><w:t>Line $i</w:t></w:r></w:p>'].join())),
    );
    await pumpView(tester, controller);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
    await tester.pumpAndSettle();
    final last = reported.last;
    expect(last[PositionKeys.viewMode], 'continuous');
    final paragraph = last[PositionKeys.paragraph]! as int;
    expect(paragraph, greaterThan(20));
    // The first paragraph still showing at the top: the one before it has
    // scrolled off.
    final top = tester.getTopLeft(find.byType(WordDocumentView)).dy;
    expect(tester.getBottomLeft(find.textContaining('Line $paragraph', findRichText: true)).dy, greaterThan(top));
    final previous = find.textContaining('Line ${paragraph - 1}', findRichText: true);
    if (previous.evaluate().isNotEmpty) expect(tester.getBottomLeft(previous).dy, lessThanOrEqualTo(top));
  });

  testWidgets('a note mark opens the note', (tester) async {
    final controller = await load(
      tester,
      buildDocx(
        '<w:p><w:r><w:t>Claim</w:t></w:r><w:r><w:footnoteReference w:id="1"/></w:r></w:p>',
        footnotes: '<w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r>'
            '<w:r><w:t xml:space="preserve"> The source.</w:t></w:r></w:p></w:footnote>',
      ),
    );
    await pumpView(tester, controller);
    expect(find.text('Notes'), findsOneWidget);
    await tester.tap(find.text('1').first);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.textContaining('The source.', findRichText: true)),
        findsOneWidget);
  });

  testWidgets('a damaged file is a typed error', (tester) async {
    final controller = await load(tester, Uint8List.fromList([1, 2, 3]));
    expect(controller.error, DocumentLoadError.corrupted);
  });

  test('rejecting after dispose does nothing', () {
    final controller = WordDocumentController()..dispose();
    expect(controller.rejectAsCorrupted, returnsNormally);
    expect(controller.error, isNull);
  });

  testWidgets('malformed table spans render', (tester) async {
    for (final span in ['-1', '0', '3000000']) {
      final controller = await load(
        tester,
        buildDocx('<w:tbl><w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid><w:tr>'
            '<w:tc><w:tcPr><w:gridSpan w:val="$span"/></w:tcPr><w:p/></w:tc>'
            '<w:tc><w:p><w:r><w:t>cell $span</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'),
      );
      expect(controller.error, isNull);
      await pumpView(tester, controller);
      expect(tester.takeException(), isNull);
      expect(shows('cell $span'), isTrue);
    }
  });

  testWidgets('on pages, the paragraph at the top is never the header or footer', (tester) async {
    const r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
    final reported = <ReadingPosition>[];
    final controller = WordDocumentController(onPositionChanged: reported.add);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.load(buildDocx(
          '${[for (var i = 0; i < 300; i++) '<w:p><w:r><w:t>Line $i</w:t></w:r></w:p>'].join()}'
          '<w:sectPr><w:headerReference w:type="default" r:id="rH"/>'
          '<w:footerReference w:type="default" r:id="rF"/></w:sectPr>',
          relationships: '<Relationship Id="rH" Type="$r/header" Target="header1.xml"/>'
              '<Relationship Id="rF" Type="$r/footer" Target="footer1.xml"/>',
          media: {
            'header1.xml': '<w:hdr xmlns:w="$w"><w:p><w:r><w:t>HEADER</w:t></w:r></w:p></w:hdr>'.codeUnits,
            'footer1.xml': '<w:ftr xmlns:w="$w"><w:p><w:r><w:t>FOOTER</w:t></w:r></w:p></w:ftr>'.codeUnits,
          },
        )));
    controller.viewMode = WordViewMode.paged;
    await pumpView(tester, controller);
    final layout = controller.layout!;
    expect(layout.paragraphs.first.plainText, 'HEADER');
    expect(layout.paragraphs.last.plainText, 'FOOTER');
    final tops = <int>{};
    for (var offset = 200.0; offset < 4000; offset += 37) {
      controller.scrollController.jumpTo(offset);
      await tester.pump();
      await tester.pump();
      if (reported.lastOrNull?[PositionKeys.paragraph] case final int paragraph) tops.add(paragraph);
    }
    expect(tops, isNotEmpty);
    expect(tops.every((n) => n > 0 && n < layout.paragraphs.length - 1), isTrue, reason: '$tops');
  });
}
