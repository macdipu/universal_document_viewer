import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';
import 'package:universal_document_viewer/src/pdf_reader/pdf_image_cache.dart';

const _features = 'test/fixtures/pdf/features.pdf';

/// Lets real work (the PDF worker, image decoding) run until [done], pumping
/// frames in between.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out');
}

double _zoom(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
  return viewer.transformationController!.value.getMaxScaleOnAxis();
}

void main() {
  test('the image cache never evicts what the view wants', () async {
    final document = await PdfiumDocument.openFile(_features);
    // A budget smaller than one image: only unwanted images may go.
    final cache = PdfImageCache(document, maxBytes: 1);
    final arrived = Completer<void>();
    cache.addListener(() {
      if (!arrived.isCompleted && [0, 1, 2, 3].every((p) => cache.base(p) != null)) arrived.complete();
    });
    cache.request(
      basePages: [0, 1, 2, 3],
      visiblePages: {0, 1, 2, 3},
      baseWidth: (_) => 256,
      tileFullSize: (_) => Size.zero,
    );
    await arrived.future.timeout(const Duration(seconds: 10));
    for (final page in [0, 1, 2, 3]) {
      expect(cache.base(page), isNotNull, reason: 'page $page');
    }
    cache.dispose();
    await document.close();
  });

  test('opening while an open is under way reuses it', () async {
    final controller = PdfDocumentController();
    final first = controller.open(_features);
    expect(identical(controller.open(_features), first), isTrue);
    await first;
    final document = controller.document;
    expect(document, isNotNull);
    await controller.open(_features);
    expect(identical(controller.document, document), isTrue);
    controller.dispose();
  });

  testWidgets('a resize keeps the zoom and the page being read', (tester) async {
    addTearDown(tester.view.reset);
    final controller = PdfDocumentController();
    await tester.pumpWidget(MaterialApp(home: PdfDocumentView(path: _features, controller: controller)));
    await _until(tester, () => controller.isReady);
    await tester.pump();
    await tester.pump();
    controller.jumpToPage(3);
    await controller.zoomIn();
    await controller.zoomIn();
    await tester.pump();
    await tester.pump();
    expect(_zoom(tester), closeTo(1.5, 0.001));
    expect(controller.currentPage, 3);

    // The keyboard opens: the view gets shorter.
    tester.view.physicalSize = Size(tester.view.physicalSize.width, tester.view.physicalSize.height / 2);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(_zoom(tester), closeTo(1.5, 0.001));
    expect(controller.currentPage, 3);

    // The window narrows: pages shrink, the reader stays put.
    tester.view.physicalSize = Size(tester.view.physicalSize.width * 0.75, tester.view.physicalSize.height);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(_zoom(tester), closeTo(1.5, 0.001));
    expect(controller.currentPage, 3);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => controller.dispose());
  });

  testWidgets('a new controller is opened', (tester) async {
    final first = PdfDocumentController();
    final second = PdfDocumentController();
    await tester.pumpWidget(MaterialApp(home: PdfDocumentView(path: _features, controller: first)));
    await _until(tester, () => first.isReady);
    await tester.pumpWidget(MaterialApp(home: PdfDocumentView(path: _features, controller: second)));
    await _until(tester, () => second.isReady);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      first.dispose();
      second.dispose();
    });
  });

  testWidgets('a thumbnail built before the document opens renders once it does', (tester) async {
    final controller = PdfDocumentController();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(width: 70, height: 90, child: PdfPageThumbnail(controller: controller, pageNumber: 1)),
      ),
    ));
    expect(find.byType(RawImage), findsNothing);
    await tester.runAsync(() => controller.open(_features));
    await _until(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => controller.dispose());
  });
}
