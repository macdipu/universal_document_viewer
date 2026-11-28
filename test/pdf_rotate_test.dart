import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';

const _features = 'test/fixtures/pdf/features.pdf';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out');
}

void main() {
  test('rotating a document swaps its pages\' shapes, and four turns come back', () async {
    final document = await PdfiumDocument.openFile(_features);
    final original = List<ui.Size>.of(document.pageSizes);
    expect(original.first.width, isNot(original.first.height), reason: 'the fixture page is not square');

    await document.rotate(1);
    for (var i = 0; i < original.length; i++) {
      expect(document.pageSizes[i].width, closeTo(original[i].height, 0.01), reason: 'page $i width');
      expect(document.pageSizes[i].height, closeTo(original[i].width, 0.01), reason: 'page $i height');
    }

    // What is rendered follows the new shape.
    final image = await document.renderThumbnail(0, width: 100);
    expect(image.width, 100);
    expect(image.height, closeTo(100 * original.first.width / original.first.height, 1));

    await document.rotate(-1);
    for (var i = 0; i < original.length; i++) {
      expect(document.pageSizes[i].width, closeTo(original[i].width, 0.01));
      expect(document.pageSizes[i].height, closeTo(original[i].height, 0.01));
    }
    await document.rotate(2);
    await document.rotate(2);
    expect(document.pageSizes.first.width, closeTo(original.first.width, 0.01));
    await document.close();
  });

  test('text boxes and search matches follow the turn: they stay inside the turned page', () async {
    final document = await PdfiumDocument.openFile(_features);
    final before = await document.text(0);
    expect(before.sideways, isFalse);
    expect(before.boxes.where((b) => !b.isEmpty), isNotEmpty, reason: 'the fixture page has text');
    await document.rotate(1);
    final after = await document.text(0);
    expect(after.sideways, isTrue, reason: 'a quarter turn makes the lines run down the page');
    List<String> lines(String t) => t.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList()..sort();
    expect(lines(after.text), lines(before.text), reason: 'the same lines, which PDFium may order differently');
    final size = document.pageSizes[0];
    for (final box in after.boxes.where((b) => !b.isEmpty)) {
      expect(box.left, greaterThanOrEqualTo(-1));
      expect(box.top, greaterThanOrEqualTo(-1));
      expect(box.right, lessThanOrEqualTo(size.width + 1), reason: 'box $box inside ${size.width} wide');
      expect(box.bottom, lessThanOrEqualTo(size.height + 1), reason: 'box $box inside ${size.height} high');
    }
    await document.close();
  });

  test('a rotation of nothing, or a full turn, changes nothing', () async {
    final document = await PdfiumDocument.openFile(_features);
    final original = List<ui.Size>.of(document.pageSizes);
    await document.rotate(0);
    await document.rotate(4);
    expect(document.pageSizes, original);
    await document.close();
  });

  testWidgets('the controller turns the pages, keeps the page being read, and a new file starts upright', (tester) async {
    final controller = PdfController()..loadFile(_features);
    await tester.pumpWidget(MaterialApp(home: PdfView(controller: controller)));
    await _until(tester, () => controller.status == DocumentStatus.ready);
    await tester.pump();
    await tester.pump();
    final first = controller.document!.pageSizes.first;
    await controller.jumpToPage(3);
    await tester.pump();

    await tester.runAsync(controller.rotateClockwise);
    await tester.pump();
    await tester.pump();
    expect(controller.rotation, 1);
    expect(controller.document!.pageSizes.first.width, closeTo(first.height, 0.01));
    expect(controller.currentPage, 3, reason: 'turning the pages keeps the page being read');

    await tester.runAsync(controller.rotateCounterclockwise);
    await tester.pump();
    expect(controller.rotation, 0);
    expect(controller.document!.pageSizes.first.width, closeTo(first.width, 0.01));

    await tester.runAsync(() => controller.rotate(-1));
    await tester.pump();
    expect(controller.rotation, 3, reason: 'anticlockwise from upright is three quarter turns clockwise');

    // The same file again keeps the open document; another file starts upright.
    controller.loadFile(_features);
    await tester.pump();
    expect(controller.rotation, 3);
    controller.loadFile('test/fixtures/pdf/outline.pdf');
    await _until(tester, () => controller.status == DocumentStatus.ready && controller.rotation == 0);
    expect(controller.rotation, 0);
    controller.dispose();
  });

  testWidgets('rotating before a document is open does nothing', (tester) async {
    final controller = PdfController();
    await tester.runAsync(controller.rotateClockwise);
    expect(controller.rotation, 0);
    controller.dispose();
  });
}
