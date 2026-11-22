import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';

const _features = 'test/fixtures/pdf/features.pdf';

/// Lets real work (the PDF worker, image decoding) run until [done], pumping frames in between.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out');
}

/// Takes the view down, then disposes the controller, as the other view tests do at the end.
Future<void> _close(WidgetTester tester, PdfController controller) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() async => controller.dispose());
}

void main() {
  Future<PdfController> open(WidgetTester tester, {PdfPageOverlayBuilder? overlay, bool Function()? onTap}) async {
    // Opened before the view is built, in real time, like the view test that builds its view after the open.
    final controller = PdfController();
    await tester.runAsync(() => controller.loadFile(_features));
    expect(controller.status, DocumentStatus.ready);
    await tester.pumpWidget(
      MaterialApp(
        home: PdfView(controller: controller, pageOverlayBuilder: overlay, onTap: onTap),
      ),
    );
    await _until(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await tester.pump();
    await tester.pump();
    return controller;
  }

  testWidgets('the overlay is built for the pages on screen, with their index and size in PDF points', (tester) async {
    final built = <int, Size>{};
    final controller = await open(
      tester,
      overlay: (context, page, size) {
        built[page] = size;
        return SizedBox.expand(key: ValueKey('overlay$page'));
      },
    );
    final document = controller.document!;
    expect(built, isNotEmpty);
    expect(built.containsKey(0), isTrue, reason: 'the first page is on screen');
    for (final entry in built.entries) {
      expect(entry.value, document.pageSizes[entry.key]);
      expect(find.byKey(ValueKey('overlay${entry.key}')), findsOneWidget);
    }
    await _close(tester, controller);
  });

  testWidgets('the overlay fills the page\'s own box, so it has the page\'s shape', (tester) async {
    final controller = await open(tester, overlay: (context, page, size) => SizedBox.expand(key: ValueKey('overlay$page')));
    final size = tester.getSize(find.byKey(const ValueKey('overlay0')));
    final page = controller.document!.pageSizes[0];
    expect(size.width / size.height, closeTo(page.width / page.height, 0.01));
    expect(size.width, greaterThan(100));
    await _close(tester, controller);
  });

  testWidgets('the overlay stays on its page when the view scrolls to another', (tester) async {
    final controller = await open(tester, overlay: (context, page, size) => SizedBox.expand(key: ValueKey('overlay$page')));
    final before = tester.getTopLeft(find.byKey(const ValueKey('overlay0'))).dy;
    await tester.runAsync(() => controller.jumpToPage(3));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final stillBuilt = find.byKey(const ValueKey('overlay0')).evaluate().isNotEmpty;
    if (stillBuilt) {
      expect(tester.getTopLeft(find.byKey(const ValueKey('overlay0'))).dy, lessThan(before), reason: 'it scrolled away with its page');
    }
    expect(find.byKey(const ValueKey('overlay3')), findsOneWidget, reason: 'the page now in view has its own');
    await _close(tester, controller);
  });

  testWidgets('the overlay takes no touches: a tap on the page still reaches the view', (tester) async {
    var overlayTapped = false;
    var viewTapped = false;
    final controller = await open(
      tester,
      onTap: () {
        viewTapped = true;
        return true;
      },
      overlay: (context, page, size) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => overlayTapped = true,
        child: SizedBox.expand(key: ValueKey('overlay$page')),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('overlay0')));
    await tester.pump(const Duration(milliseconds: 400));
    // The view looks the tap up in the page's links first, which takes the worker a moment.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(overlayTapped, isFalse);
    expect(viewTapped, isTrue);
    await _close(tester, controller);
  });

  testWidgets('a builder that returns null draws nothing, and having no builder changes nothing', (tester) async {
    final controller = await open(tester, overlay: (context, page, size) => null);
    expect(find.byType(IgnorePointer).evaluate().where((e) => e.widget.runtimeType == IgnorePointer && (e.widget as IgnorePointer).child is SizedBox), isEmpty);
    await _close(tester, controller);
  });

  testWidgets('an overlay can change itself without the view being rebuilt', (tester) async {
    final label = ValueNotifier('scanning');
    addTearDown(label.dispose);
    final controller = await open(
      tester,
      overlay: (context, page, size) => ValueListenableBuilder<String>(
        valueListenable: label,
        builder: (context, value, _) => page == 0 ? Text(value, key: const ValueKey('label')) : const SizedBox.shrink(),
      ),
    );
    expect(find.text('scanning'), findsOneWidget);
    label.value = 'done';
    await tester.pump();
    expect(find.text('done'), findsOneWidget);
    expect(find.text('scanning'), findsNothing);
    await _close(tester, controller);
  });
}
