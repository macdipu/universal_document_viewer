import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/engines/pdfium/pdf_engine.dart';
import 'package:universal_document_viewer/src/engines/pdfium/pdf_types.dart';

const _features = 'test/fixtures/pdf/features.pdf';

void main() {
  late PdfiumDocument doc;
  setUpAll(() async => doc = await PdfiumDocument.openFile(_features));
  tearDownAll(() => doc.close());

  test('page sizes, rotation applied', () {
    expect(doc.pageCount, 4);
    expect(doc.pageSizes[0], const Size(612, 792));
    expect(doc.pageSizes[1].width, closeTo(595.3, 0.1));
    // Landscape media turned 90 degrees by /Rotate reads as portrait.
    expect(doc.pageSizes[2], const Size(612, 792));
    expect(doc.pageSizes[3], const Size(612, 792));
  });

  test('renders a page and a region of it', () async {
    final thumb = await doc.renderThumbnail(0, width: 120);
    expect(thumb.width, 120);
    expect(thumb.height, 155);
    expect(thumb.pixels.length, 120 * 155 * 4);
    expect(thumb.pixels.any((b) => b < 200), isTrue, reason: 'some dark text pixels');
    final region = await doc.render(0, fullWidth: 1224, fullHeight: 1584, region: const Rect.fromLTWH(100, 150, 300, 100)).result;
    expect((region.width, region.height), (300, 100));
  });

  test('a rotated page renders turned', () async {
    // Drawn at (72, 500) on landscape media (792 x 612), then turned 90
    // degrees clockwise: on the portrait page it reads downwards from
    // about (500, 72).
    final image = await doc.render(2, fullWidth: 612, fullHeight: 792).result;
    int darkIn(Rect area) {
      var dark = 0;
      for (var y = area.top.toInt(); y < area.bottom; y++) {
        for (var x = area.left.toInt(); x < area.right; x++) {
          if (image.pixels[(y * image.width + x) * 4] < 128) dark++;
        }
      }
      return dark;
    }

    expect(darkIn(const Rect.fromLTWH(480, 60, 40, 140)), greaterThan(20));
    expect(darkIn(const Rect.fromLTWH(60, 480, 140, 40)), 0);
  });

  test('page text and boxes', () async {
    final text = await doc.text(0);
    expect(text.text, contains('Quarterly Report alpha'));
    expect(text.boxes, hasLength(text.text.length));
    final q = text.text.indexOf('Quarterly');
    // Drawn at x=72pt, baseline 700pt from the bottom: ~92pt from the top.
    expect(text.boxes[q].left, closeTo(72, 2));
    expect(text.boxes[q].top, inInclusiveRange(78, 92));
  });

  test('search: case, wrapped phrases, rotated pages, pages without text', () async {
    final (hasText, matches) = await doc.search(0, 'NEEDLE');
    expect(hasText, isTrue);
    expect(matches, hasLength(1));
    final (_, wrapped) = await doc.search(1, 'quarterly   report');
    expect(wrapped, hasLength(1));
    expect(wrapped.single.rects, hasLength(2), reason: 'one rect per line');
    final (_, rotated) = await doc.search(2, 'needle');
    expect(rotated, hasLength(1));
    final rect = rotated.single.rects.single;
    final page = Offset.zero & doc.pageSizes[2];
    expect(page.contains(rect.topLeft) && page.contains(rect.bottomRight), isTrue, reason: '$rect within $page');
    expect(rect.height, greaterThan(rect.width), reason: 'text runs down a page turned 90 degrees');
    final (scanned, none) = await doc.search(3, 'anything');
    expect(scanned, isFalse);
    expect(none, isEmpty);
  });

  test('links: web addresses and pages', () async {
    final links = await doc.links(0);
    expect(links.where((l) => l.url == 'https://example.com/'), isNotEmpty);
    expect(links.where((l) => l.page == 2), isNotEmpty);
  });

  test('passwords', () async {
    await expectLater(
      PdfiumDocument.openFile('test/fixtures/pdf/encrypted.pdf'),
      throwsA(isA<PdfOpenException>().having((e) => e.error, 'error', PdfOpenError.password)),
    );
    await expectLater(
      PdfiumDocument.openFile('test/fixtures/pdf/encrypted.pdf', password: 'wrong'),
      throwsA(isA<PdfOpenException>().having((e) => e.error, 'error', PdfOpenError.password)),
    );
    final secret = await PdfiumDocument.openFile('test/fixtures/pdf/encrypted.pdf', password: 'secret');
    expect((await secret.text(0)).text, contains('Top secret text'));
    await secret.close();
  });

  test('damaged and missing files', () async {
    await expectLater(
      PdfiumDocument.openFile('test/fixtures/pdf/broken.pdf'),
      throwsA(isA<PdfOpenException>().having((e) => e.error, 'error', PdfOpenError.format)),
    );
    await expectLater(
      PdfiumDocument.openFile('test/fixtures/pdf/missing.pdf'),
      throwsA(isA<PdfOpenException>().having((e) => e.error, 'error', PdfOpenError.file)),
    );
  });

  test('queued renders can be cancelled', () async {
    final tasks = [
      for (var i = 0; i < 6; i++) doc.render(i % 4, fullWidth: 1200, fullHeight: 1550, priority: PdfPriority.background),
    ];
    tasks.last.cancel();
    await expectLater(tasks.last.result, throwsA(isA<PdfCancelledException>()));
    for (final task in tasks.take(5)) {
      expect((await task.result).width, 1200);
    }
  });

  test('a render cancelled with nobody waiting is not an uncaught error', () async {
    // An uncaught error here would fail the test.
    doc.render(0, fullWidth: 600, fullHeight: 775, priority: PdfPriority.background).cancel();
    await doc.renderThumbnail(0, width: 60);
  });

  test('a thumbnail of a page out of range fails with a typed error', () async {
    await expectLater(doc.renderThumbnail(4, width: 60), throwsA(isA<PdfEngineException>()));
    await expectLater(doc.renderThumbnail(-1, width: 60), throwsA(isA<PdfEngineException>()));
  });

  test('close goes ahead of queued renders and drops them', () async {
    final other = await PdfiumDocument.openFile(_features);
    final queued = [
      for (var i = 0; i < 8; i++)
        other.render(i % 4, fullWidth: 1600, fullHeight: 2070, priority: PdfPriority.background).result,
    ];
    final outcomes = [
      for (final render in queued) render.then<Object>((image) => image, onError: (Object e) => e),
    ];
    await other.close();
    final dropped = (await Future.wait(outcomes)).whereType<PdfEngineException>();
    expect(dropped, isNotEmpty, reason: 'renders queued behind the close are answered as closed');
    // The shared worker carries on for other documents.
    expect((await doc.renderThumbnail(0, width: 60)).width, 60);
  });
}
