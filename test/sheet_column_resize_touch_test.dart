import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/spreadsheet.dart';
import 'package:universal_document_viewer/testing.dart';

/// Resizing a column by touch (view only): select the header and drag the
/// grip on its right edge, or long-press the edge between two headers and
/// drag with the same finger. Fit and original width are in the status
/// bar's column menu.
void main() {
  Future<SpreadsheetController> load(WidgetTester tester) async {
    final controller = SpreadsheetController();
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.loadBytes(
        buildXlsx([
          XlsxTestSheet('S', {
            'A1': 'Item',
            'B1': 'Qty',
            'C1': 'Note',
            'D1': 'More',
            for (var r = 2; r <= 60; r++) ...{'A$r': 'a$r', 'B$r': r, 'C$r': 'x', 'D$r': 'd$r'},
          }),
        ]),
      ),
    );
    return controller;
  }

  Future<void> pump(WidgetTester tester, SpreadsheetController controller) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: SpreadsheetView(controller: controller)),
      ),
    );
    await tester.pump();
  }

  double widthOf(SpreadsheetController c, int column) => c.geometry.columnWidth(column);

  Finder grip() => find.byKey(const Key('column-resize-grip'));

  // Column C is the third: it starts after the 40 px row numbers and two
  // 104 px columns, so its right edge is at 40 + 3 * 104 = 352.
  const edgeOfC = 352.0;

  testWidgets('tapping a column header shows a grip on its right edge; a mouse click does not', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    expect(grip(), findsNothing);
    await tester.tap(find.text('C'));
    await tester.pump();
    expect(grip(), findsOneWidget);
    expect(tester.getCenter(grip()).dx, closeTo(edgeOfC, 1), reason: 'centred on the edge between C and D');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('B')));
    await mouse.down(tester.getCenter(find.text('B')));
    await mouse.up();
    await tester.pump();
    expect(grip(), findsNothing, reason: 'a mouse has the edge handle instead');
  });

  testWidgets('dragging the grip resizes the column, with a guide line, without scrolling', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('C'));
    await tester.pump();
    final before = widthOf(controller, 2);

    final gesture = await tester.startGesture(tester.getCenter(grip()));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(widthOf(controller, 2), closeTo(before + 60, 2));
    bool guide() => tester.widgetList<ColoredBox>(find.byType(ColoredBox)).any((b) => (b.color.a - 0.85).abs() < 0.01);
    expect(guide(), isTrue, reason: 'a guide line shows the new edge');
    expect(controller.horizontalController.offset, 0, reason: 'the grid did not scroll');
    expect(controller.selection.value, const GridSelection.column(2));

    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    expect(widthOf(controller, 2), 24, reason: 'never narrower than 24 px');
    await gesture.up();
    await tester.pump();
    expect(guide(), isFalse, reason: 'the guide goes when the finger lifts');
    expect(controller.hasColumnWidthOverride(2), isTrue);
    expect(controller.currentSheet!.layout.columnWidths, isEmpty, reason: 'the file is untouched');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the grip moves with the edge, and the width follows the finger when zoomed', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    controller.setZoom(1.5);
    await tester.pump();
    await tester.tap(find.text('B'));
    await tester.pump();
    final before = widthOf(controller, 1);
    final start = tester.getCenter(grip());
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(15, 0));
    await gesture.moveBy(const Offset(15, 0));
    await tester.pump();
    expect(widthOf(controller, 1), closeTo(before + 30 / 1.5, 2), reason: 'screen pixels / zoom');
    await gesture.up();
    await tester.pump();
    expect(tester.getCenter(grip()).dx, closeTo(start.dx + 30, 2), reason: 'the grip stays on the edge');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a double tap on the grip fits the column to its text', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('C'));
    await tester.pump();
    final before = widthOf(controller, 2);
    await tester.tap(grip());
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(grip());
    await tester.pumpAndSettle();
    expect(widthOf(controller, 2), lessThan(before), reason: 'the notes are one letter: much narrower');
    expect(controller.hasColumnWidthOverride(2), isTrue);
  });

  testWidgets('fit measures with the given base style (the view passes the one the cells inherit)', (tester) async {
    final controller = await load(tester);
    controller.autoFitColumn(2);
    final plain = widthOf(controller, 2);
    controller.autoFitColumn(2, baseStyle: const TextStyle(letterSpacing: 6));
    expect(widthOf(controller, 2), greaterThan(plain), reason: 'wide letters need a wider column');
  });

  testWidgets('a long press on the edge between two headers starts resizing; the same finger drags', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final before = widthOf(controller, 2);
    final gesture = await tester.startGesture(const Offset(edgeOfC - 8, 22));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(controller.selection.value, const GridSelection.column(2), reason: 'the column is selected');
    await gesture.moveBy(const Offset(25, 0));
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    expect(widthOf(controller, 2), closeTo(before + 50, 2));
    expect(controller.horizontalController.offset, 0);
    await gesture.up();
    await tester.pump();
    // Free to scroll again at once.
    await tester.drag(find.text('a9'), const Offset(0, -200));
    await tester.pump();
    expect(controller.verticalController.offset, greaterThan(50));
  });

  testWidgets('a swipe along the headers still scrolls (no resize without the long press)', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final before = widthOf(controller, 2);
    await tester.dragFrom(const Offset(edgeOfC - 8, 22), const Offset(-120, 0));
    await tester.pump();
    expect(widthOf(controller, 2), before);
    expect(controller.horizontalController.offset, greaterThan(50), reason: 'it scrolled');
  });

  testWidgets('the status bar menu fits the column or restores its original width', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('C'));
    await tester.pump();
    final original = widthOf(controller, 2);

    await tester.tap(find.byTooltip('Column width'));
    await tester.pumpAndSettle();
    expect(find.text('Fit to content'), findsOneWidget);
    // Nothing changed yet, so there is no original width to go back to.
    final reset = tester.widget<PopupMenuItem<String>>(find.widgetWithText(PopupMenuItem<String>, 'Original width'));
    expect(reset.enabled, isFalse);
    await tester.tap(find.text('Fit to content'));
    await tester.pumpAndSettle();
    expect(widthOf(controller, 2), lessThan(original));

    await tester.tap(find.byTooltip('Column width'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Original width'));
    await tester.pumpAndSettle();
    expect(widthOf(controller, 2), original);
    expect(controller.hasColumnWidthOverride(2), isFalse);
  });

  testWidgets('no column menu for a cell selection', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('a2'));
    await tester.pump();
    expect(find.byTooltip('Column width'), findsNothing);
    expect(grip(), findsNothing);
  });
}
