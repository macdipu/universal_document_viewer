import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';
import 'package:universal_document_viewer/src/pdf/pdf_selection.dart';
import 'package:universal_document_viewer/src/pdf/pdf_text_layer.dart';

const _features = 'test/fixtures/pdf/features.pdf';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out');
}

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

  /// Opens the fixture; returns how to find a word's centre on screen.
  Future<(PdfController, Offset Function(String word, {bool end}))> open(
    WidgetTester tester, {
    PdfSelectionMenuItems? menu,
  }) async {
    final controller = PdfController();
    addTearDown(() => tester.runAsync(() async => controller.dispose()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfView(controller: controller, selectionMenuItems: menu),
        ),
      ),
    );
    await tester.runAsync(() => controller.loadFile(_features));
    await _until(tester, () => controller.status == DocumentStatus.ready);
    final PdfTextLayer layer = (await tester.runAsync<PdfTextLayer?>(() => controller.selection.loadLayer(0)))!;
    await tester.pump();
    await tester.pump();
    Offset where(String word, {bool end = false}) {
      final page = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PdfPage').first;
      final rect = tester.getRect(page);
      final factor = rect.width / controller.document!.pageSizes[0].width;
      final at = layer.text.indexOf(word);
      expect(at, isNonNegative, reason: word);
      final box = end ? layer.boxes[at + word.length - 1] : layer.boxes[at];
      final x = end ? box.right - 1 : box.left + 1;
      return rect.topLeft + Offset(x, box.center.dy) * factor;
    }

    return (controller, where);
  }

  var nextPointer = 100;
  Future<TestGesture> mouse(WidgetTester tester, Offset at, {int buttons = kPrimaryMouseButton}) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: buttons, pointer: nextPointer++);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(at);
    await tester.pump();
    return gesture;
  }

  testWidgets('dragging the mouse over text selects it, Ctrl+C copies', (tester) async {
    final (controller, where) = await open(tester);
    final gesture = await mouse(tester, where('Quarterly'));
    await gesture.down(where('Quarterly'));
    await tester.pump();
    final end = where('Report', end: true);
    for (var i = 1; i <= 5; i++) {
      await gesture.moveTo(Offset.lerp(where('Quarterly'), end, i / 5)!);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    expect(controller.hasSelection.value, isTrue);
    expect(controller.selectedText(), 'Quarterly Report');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(clipboard, 'Quarterly Report');
    expect(find.text('Text copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a double click selects a word, a triple click the line, and neither zooms', (tester) async {
    final (controller, where) = await open(tester);
    final viewer = find.byType(InteractiveViewer);
    double zoom() => tester.widget<InteractiveViewer>(viewer).transformationController!.value.getMaxScaleOnAxis();

    final at = where('Quarterly');
    await mouse(tester, at);
    Future<void> click() async {
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 20));
    }

    await click();
    await click();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.selectedText(), 'Quarterly');
    expect(zoom(), closeTo(1, 0.001));

    await click();
    await click();
    await click();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.selectedText(), startsWith('Quarterly Report alpha'));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a plain click clears the selection', (tester) async {
    final (controller, where) = await open(tester);
    controller.selection.select(const PdfCaret(0, 0), const PdfCaret(0, 5));
    await tester.pump();
    expect(controller.hasSelection.value, isTrue);
    await mouse(tester, where('Quarterly'));
    await tester.tapAt(where('Quarterly'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.hasSelection.value, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('right click selects the word and opens a menu with Copy, Select all and the app\'s items', (
    tester,
  ) async {
    var extraTapped = false;
    final (controller, where) = await open(
      tester,
      menu: (context, c) => [ContextMenuButtonItem(label: 'Highlight', onPressed: () => extraTapped = true)],
    );
    await mouse(tester, where('Quarterly'));
    await tester.tapAt(where('Quarterly'), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();

    expect(controller.selectedText(), 'Quarterly');
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Highlight'), findsOneWidget);

    await tester.tap(find.text('Highlight'));
    await tester.pump();
    expect(extraTapped, isTrue);
    expect(find.text('Copy'), findsNothing, reason: 'the menu closes');

    // Open it again and copy.
    await tester.tapAt(where('Quarterly'), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(clipboard, 'Quarterly');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Select all selects the document, Esc clears it', (tester) async {
    final (controller, where) = await open(tester);
    await mouse(tester, where('Quarterly'));
    await tester.tapAt(where('Quarterly'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    expect(controller.selection.anchor, const PdfCaret(0, 0));
    expect(controller.selection.focus!.offset, PdfCaret.end);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.hasSelection.value, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  group('touch', () {
    final handles = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_HandlePainter',
    );

    testWidgets('a long press selects the word, shows handles and a toolbar, Copy copies', (tester) async {
      final (controller, where) = await open(tester);
      await tester.longPressAt(where('Quarterly'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();

      expect(controller.selectedText(), 'Quarterly');
      expect(handles, findsNWidgets(2));
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);

      await tester.tap(find.text('Copy'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(clipboard, 'Quarterly');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('dragging the end handle extends the selection, and the toolbar returns on release', (tester) async {
      final (controller, where) = await open(tester);
      await tester.longPressAt(where('Quarterly'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(controller.selectedText(), 'Quarterly');

      final end = tester.getCenter(handles.last);
      final target = where('Report', end: true) + const Offset(0, 28);
      final drag = await tester.startGesture(end);
      for (var i = 1; i <= 6; i++) {
        await drag.moveTo(Offset.lerp(end, target, i / 6)!);
        await tester.pump();
      }
      expect(find.text('Copy'), findsNothing, reason: 'hidden while dragging');
      await drag.up();
      await tester.pump();

      expect(controller.selectedText(), 'Quarterly Report');
      expect(find.text('Copy'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a tap elsewhere clears the selection, the handles and the toolbar', (tester) async {
      final (controller, where) = await open(tester);
      await tester.longPressAt(where('Quarterly'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(handles, findsNWidgets(2));

      await tester.tapAt(where('alpha') + const Offset(0, 90));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.hasSelection.value, isFalse);
      expect(handles, findsNothing);
      expect(find.text('Copy'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a long press on blank paper selects nothing', (tester) async {
      final (controller, _) = await open(tester);
      final page = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PdfPage').first;
      await tester.longPressAt(tester.getBottomRight(page) - const Offset(10, 10));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(controller.hasSelection.value, isFalse);
      expect(handles, findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
