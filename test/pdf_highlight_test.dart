import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';
import 'package:universal_document_viewer/src/pdf/pdf_selection.dart';

const _features = 'test/fixtures/pdf/features.pdf';

void main() {
  late PdfController controller;

  setUp(() async {
    controller = PdfController();
    await controller.loadFile(_features);
    expect(controller.error, isNull);
  });
  tearDown(() => controller.dispose());

  test('nothing selected gives no ranges', () async {
    expect(await controller.selectedRanges(), isEmpty);
  });

  test('the selection comes back as a range on its page, with its words', () async {
    final layer = (await controller.selection.loadLayer(0))!;
    final from = layer.text.indexOf('Quarterly');
    controller.selection.select(PdfCaret(0, from), PdfCaret(0, from + 'Quarterly Report'.length));
    final ranges = await controller.selectedRanges();
    expect(ranges, [
      PdfTextRange(page: 0, start: from, end: from + 'Quarterly Report'.length, text: 'Quarterly Report'),
    ]);
  });

  test('a selection over pages gives a range per page that has text', () async {
    controller.selection.select(const PdfCaret(0, 0), const PdfCaret(3, PdfCaret.end));
    final ranges = await controller.selectedRanges();
    expect(ranges.map((r) => r.page), [0, 1, 2], reason: 'page 4 is a scan with no text');
    expect(ranges.first.text, contains('Quarterly Report alpha'));
  });

  test('highlights are drawn over the range they mark, in their colour', () async {
    final layer = (await controller.selection.loadLayer(0))!;
    final from = layer.text.indexOf('Quarterly');
    final range = PdfTextRange(page: 0, start: from, end: from + 9, text: 'Quarterly');
    var notified = 0;
    controller.selection.addListener(() => notified++);

    controller.setHighlights([PdfHighlight(range: range, color: const Color(0xFFFFEB3B))]);
    expect(controller.highlights.single.range, range);
    final marks = controller.selection.highlightRectsOn(0);
    expect(marks, hasLength(1));
    expect(marks.single.$1.left, closeTo(72, 2));
    expect(marks.single.$2, const Color(0xFFFFEB3B));
    expect(controller.selection.highlightRectsOn(1), isEmpty);
    expect(notified, greaterThan(0), reason: 'the view repaints');

    controller.setHighlights(const []);
    expect(controller.selection.highlightRectsOn(0), isEmpty);
  });

  test('highlights on a page not read yet are drawn once it has been', () async {
    final fresh = PdfController();
    addTearDown(fresh.dispose);
    await fresh.loadFile(_features);
    fresh.setHighlights([
      const PdfHighlight(
        range: PdfTextRange(page: 0, start: 0, end: 5, text: 'x'),
        color: Color(0xFF00FF00),
      ),
    ]);
    expect(fresh.selection.highlightRectsOn(0), isEmpty, reason: 'text not read yet');
    await fresh.selection.loadLayer(0);
    expect(fresh.selection.highlightRectsOn(0), isNotEmpty);
  });

  test('opening another document drops the highlights', () async {
    controller.setHighlights([
      const PdfHighlight(
        range: PdfTextRange(page: 0, start: 0, end: 5, text: 'x'),
        color: Color(0xFF00FF00),
      ),
    ]);
    await controller.loadFile('test/fixtures/pdf/outline.pdf');
    expect(controller.highlights, isEmpty);
  });

  test('ranges and highlights compare by value', () {
    const a = PdfTextRange(page: 1, start: 2, end: 3, text: 't');
    expect(a, const PdfTextRange(page: 1, start: 2, end: 3, text: 't'));
    expect(a == const PdfTextRange(page: 1, start: 2, end: 4, text: 't'), isFalse);
    expect(
      const PdfHighlight(range: a, color: Color(0xFF000000)),
      const PdfHighlight(range: a, color: Color(0xFF000000)),
    );
  });
}
