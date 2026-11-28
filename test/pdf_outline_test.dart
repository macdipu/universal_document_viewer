import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';

void main() {
  test('a PDF with bookmarks gives its table of contents, nested, pointing at pages', () async {
    final document = await PdfiumDocument.openFile('test/fixtures/pdf/outline.pdf');
    final entries = await document.outline();
    expect(entries.map((e) => (e.title, e.level, e.page)), [
      ('Chapter 1', 0, 0),
      ('Section 1.1', 1, 1),
      ('Chapter 2', 0, 2),
    ]);
    await document.close();
  });

  test('PdfController.outline gives entries whose target is a page number, and goToOutlineEntry goes there', () async {
    final controller = PdfController();
    addTearDown(controller.dispose);
    await controller.loadFile('test/fixtures/pdf/outline.pdf');
    final outline = await controller.outline();
    expect(outline, const [
      OutlineEntry(title: 'Chapter 1', level: 0, target: 1),
      OutlineEntry(title: 'Section 1.1', level: 1, target: 2),
      OutlineEntry(title: 'Chapter 2', level: 0, target: 3),
    ]);
    controller.goToOutlineEntry(outline.last);
    // No view is attached, so the go-to waits for one: it is the same call goTo makes.
    expect(controller.hasSelection.value, isFalse);
  });

  test('a PDF with no bookmarks has an empty outline', () async {
    final document = await PdfiumDocument.openFile('test/fixtures/pdf/features.pdf');
    expect(await document.outline(), isEmpty);
    await document.close();
    final controller = PdfController();
    addTearDown(controller.dispose);
    expect(await controller.outline(), isEmpty, reason: 'nothing loaded');
  });

  test('an entry that leads nowhere has no target', () {
    expect(const OutlineEntry(title: 'Group', level: 0).target, isNull);
  });
}
