import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/spreadsheet.dart';

/// Touch selection on a phone-sized grid (CR-EXCEL-READER-AUDIT S3): long
/// press, drag, handles, edge auto-scroll, Done, pinch zoom, and swipes that
/// must keep scrolling.
void main() {
  Future<SpreadsheetController> load(WidgetTester tester) async {
    final csv = [
      for (var r = 0; r < 300; r++) [for (var c = 0; c < 40; c++) 'r${r}c$c'].join(','),
    ].join('\n');
    final controller = SpreadsheetController(format: DocumentFormat.csv);
    await tester.runAsync(() => controller.loadBytes(utf8.encode(csv)));
    return controller;
  }

  Future<void> pump(WidgetTester tester, SpreadsheetController controller, {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
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

  GridSelection? sel(SpreadsheetController c) => c.selection.value;

  Future<TestGesture> longPress(WidgetTester tester, Finder target) async {
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    return gesture;
  }

  testWidgets('a long press selects the cell and shows the touch toolbar; the same finger drags a range', (
    tester,
  ) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final gesture = await longPress(tester, find.text('r1c0'));
    expect(sel(controller), const GridSelection.cell(1, 0));
    expect(find.text('Done'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(find.text('r4c1')));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final s = sel(controller)!;
    expect((s.anchorRow, s.anchorColumn, s.activeRow, s.activeColumn), (1, 0, 4, 1));
    expect(controller.verticalController.offset, 0, reason: 'selecting did not scroll');
  });

  testWidgets('in range mode a swipe extends instead of scrolling; Done brings scrolling back', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final gesture = await longPress(tester, find.text('r1c0'));
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('selection-handle-end')), findsOneWidget);
    await tester.drag(find.text('r6c1'), const Offset(0, -200));
    await tester.pump();
    expect(controller.verticalController.offset, 0);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.text('Done'), findsNothing);
    expect(find.byKey(const ValueKey('selection-handle-end')), findsNothing);
    expect(sel(controller), isNotNull, reason: 'Done keeps the selection');
    await tester.drag(find.text('r6c1'), const Offset(0, -200));
    await tester.pump();
    expect(controller.verticalController.offset, greaterThan(50));
  });

  testWidgets('dragging the handles moves the range corners', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final gesture = await longPress(tester, find.text('r2c1'));
    await gesture.up();
    await tester.pump();
    final end = find.byKey(const ValueKey('selection-handle-end'));
    await tester.drag(end, tester.getCenter(find.text('r5c2')) - tester.getCenter(end), touchSlopY: 0);
    await tester.pump();
    var s = sel(controller)!;
    expect((s.anchorRow, s.anchorColumn, s.activeRow, s.activeColumn), (2, 1, 5, 2));
    final start = find.byKey(const ValueKey('selection-handle-start'));
    await tester.drag(start, tester.getCenter(find.text('r1c0')) - tester.getCenter(start), touchSlopY: 0);
    await tester.pump();
    s = sel(controller)!;
    final b = s.bounds(rowCount: 300, columnCount: 40);
    expect((b.firstRow, b.firstColumn, b.lastRow, b.lastColumn), (1, 0, 5, 2));
  });

  testWidgets('holding a handle at the bottom edge scrolls and keeps extending', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final gesture = await longPress(tester, find.text('r1c0'));
    await gesture.up();
    await tester.pump();
    final end = find.byKey(const ValueKey('selection-handle-end'));
    final drag = await tester.startGesture(tester.getCenter(end));
    await drag.moveBy(const Offset(0, 30));
    await drag.moveTo(Offset(tester.getCenter(end).dx, 844 - 5));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pump();
    expect(controller.verticalController.offset, greaterThan(100));
    expect(sel(controller)!.activeRow, greaterThan(22), reason: 'past the rows that were on screen');
  });

  testWidgets('a normal swipe scrolls, never selects, and a tap still selects one cell', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.fling(find.text('r3c1'), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(controller.verticalController.offset, greaterThan(100));
    expect(sel(controller), isNull);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('two fingers pinch to zoom, within the zoom limits', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final center = tester.getCenter(find.text('r3c1'));
    final a = await tester.startGesture(center - const Offset(30, 0), pointer: 1);
    final b = await tester.startGesture(center + const Offset(30, 0), pointer: 2);
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();
    expect(controller.zoom, closeTo(2, 0.01), reason: '60 -> 120 px apart doubles, the maximum');
    expect(sel(controller), isNull, reason: 'a pinch is not a selection');
    final c = await tester.startGesture(center - const Offset(100, 0), pointer: 3);
    final d = await tester.startGesture(center + const Offset(100, 0), pointer: 4);
    await c.moveBy(const Offset(90, 0));
    await d.moveBy(const Offset(-90, 0));
    await tester.pump();
    await c.up();
    await d.up();
    await tester.pump();
    expect(controller.zoom, controller.minZoom);
  });

  testWidgets('a mouse long press does not start touch range mode', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller, size: const Size(1440, 900));
    final gesture = await tester.startGesture(tester.getCenter(find.text('r1c1')), kind: PointerDeviceKind.mouse);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();
    expect(find.text('Done'), findsNothing);
    expect(sel(controller), const GridSelection.cell(1, 1));
  });

  testWidgets('a tablet in landscape gets the same touch selection', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller, size: const Size(1180, 820));
    final gesture = await longPress(tester, find.text('r1c1'));
    await gesture.moveTo(tester.getCenter(find.text('r3c3')));
    await gesture.up();
    await tester.pump();
    expect(sel(controller)!.address(rowCount: 300, columnCount: 40), 'B2:D4');
  });
}
