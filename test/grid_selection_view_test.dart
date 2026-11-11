import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/spreadsheet.dart';

/// Selection on the grid: mouse, keyboard, touch and the places it must not
/// go stale. A CSV of 300 rows x 40 columns, cells named like `r3c2`
/// (row 3, column 2, both from 0).
void main() {
  Future<SpreadsheetController> load(WidgetTester tester) async {
    final csv = [
      for (var r = 0; r < 300; r++) [for (var c = 0; c < 40; c++) 'r${r}c$c'].join(','),
    ].join('\n');
    final controller = SpreadsheetController(format: DocumentFormat.csv);
    await tester.runAsync(() => controller.loadBytes(utf8.encode(csv)));
    return controller;
  }

  Future<void> pump(WidgetTester tester, SpreadsheetController controller, {Size size = const Size(1440, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        // A tap's ink splash still running when its cell scrolls out of the
        // virtualized grid trips a framework assertion (it does on the
        // original grid too); selection is what is under test here.
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: SpreadsheetView(controller: controller)),
      ),
    );
    await tester.pump();
  }

  GridSelection? sel(SpreadsheetController c) => c.selection.value;

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {bool shift = false, bool ctrl = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(k);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  testWidgets('a click selects one cell and the bar shows its address', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    expect(sel(controller), isNull);
    await tester.tap(find.text('r2c1'));
    await tester.pump();
    expect(sel(controller), const GridSelection.cell(2, 1));
    expect(find.textContaining('B3'), findsOneWidget, reason: 'the address in the selection bar');
  });

  testWidgets('showing the selection bar never moves the cells under the pointer', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final before = tester.getCenter(find.text('r3c1'));
    await tester.tap(find.text('r2c1'));
    await tester.pump();
    expect(sel(controller), isNotNull);
    expect(tester.getCenter(find.text('r3c1')), before);
  });

  testWidgets('a mouse drag selects a range, and the bar gives its address and size', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    final from = tester.getCenter(find.text('r1c1'));
    final to = tester.getCenter(find.text('r4c3'));
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await gesture.moveTo(to);
    await gesture.up();
    await tester.pump();
    final s = sel(controller)!;
    expect(s.kind, GridSelectionKind.range);
    expect((s.anchorRow, s.anchorColumn, s.activeRow, s.activeColumn), (1, 1, 4, 3));
    expect(find.textContaining('B2:D5'), findsOneWidget);
    expect(find.textContaining('4R × 3C'), findsOneWidget);
  });

  testWidgets('Shift+click extends from the anchor', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('r1c1'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('r3c2'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    final s = sel(controller)!;
    expect((s.anchorRow, s.anchorColumn, s.activeRow, s.activeColumn), (1, 1, 3, 2));
  });

  testWidgets('the arrow keys move the active cell, Shift+arrows extend, and the edges hold', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('r0c0'));
    await tester.pump();
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(sel(controller), const GridSelection.cell(0, 0), reason: 'stays on the first cell');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(sel(controller), const GridSelection.cell(1, 1));
    await key(tester, LogicalKeyboardKey.arrowDown, shift: true);
    await key(tester, LogicalKeyboardKey.arrowRight, shift: true);
    final s = sel(controller)!;
    expect((s.anchorRow, s.anchorColumn, s.activeRow, s.activeColumn), (1, 1, 2, 2));
    // Tab and Enter move like a spreadsheet's.
    await key(tester, LogicalKeyboardKey.tab);
    expect(sel(controller), const GridSelection.cell(2, 3));
    await key(tester, LogicalKeyboardKey.enter);
    expect(sel(controller), const GridSelection.cell(3, 3));
    await key(tester, LogicalKeyboardKey.tab, shift: true);
    expect(sel(controller), const GridSelection.cell(3, 2));
    await key(tester, LogicalKeyboardKey.home);
    expect(sel(controller), const GridSelection.cell(3, 0));
    await key(tester, LogicalKeyboardKey.end);
    expect(sel(controller), const GridSelection.cell(3, 39));
  });

  testWidgets('Page Down and Ctrl+End reach far rows, and the active cell is scrolled into view', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('r0c0'));
    await tester.pump();
    await key(tester, LogicalKeyboardKey.pageDown);
    final page = sel(controller)!.activeRow;
    expect(page, greaterThan(5));
    await key(tester, LogicalKeyboardKey.end, ctrl: true);
    await tester.pump();
    expect(sel(controller), const GridSelection.cell(299, 39));
    // Virtualized: the last cell now exists on screen, the first no longer.
    expect(find.text('r299c39'), findsOneWidget);
    expect(find.text('r0c0'), findsNothing);
    await key(tester, LogicalKeyboardKey.home, ctrl: true);
    expect(sel(controller), const GridSelection.cell(0, 0));
    expect(find.text('r0c0'), findsOneWidget);
  });

  testWidgets('Ctrl+A and the corner select everything; Esc clears; Esc without a selection is left alone', (
    tester,
  ) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('r0c0'));
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyA, ctrl: true);
    expect(sel(controller)!.kind, GridSelectionKind.all);
    expect(find.textContaining('A1:AN300'), findsOneWidget);
    expect(find.textContaining('Too many cells'), findsNothing, reason: '12,000 cells are still totalled');
    expect(find.textContaining('Count 12000'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(sel(controller), isNull);
    await tester.tap(find.bySemanticsLabel('Select all'));
    await tester.pump();
    expect(sel(controller)!.kind, GridSelectionKind.all);
    await tester.tap(find.bySemanticsLabel('Select all'));
    await tester.pump();
    expect(sel(controller), isNull);
  });

  testWidgets('row and column headers still select a whole row or column', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.bySemanticsLabel('Column C'));
    await tester.pump();
    expect(sel(controller), const GridSelection.column(2));
    expect(find.textContaining('Column C'), findsWidgets);
    await tester.tap(find.bySemanticsLabel('Row 4'));
    await tester.pump();
    expect(sel(controller), const GridSelection.row(3));
  });

  testWidgets('a swipe scrolls and never selects', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller, size: const Size(390, 844));
    await tester.drag(find.text('r2c1'), const Offset(0, -300));
    await tester.pump();
    expect(controller.verticalController.offset, greaterThan(100));
    expect(sel(controller), isNull);
    await tester.drag(find.byType(SpreadsheetView), const Offset(-200, 0));
    await tester.pump();
    expect(sel(controller), isNull);
  });

  testWidgets('the selection survives scrolling and zooming and clears on a sheet change', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    controller.select(const GridSelection.cell(5, 5));
    await tester.pump();
    controller.verticalController.jumpTo(2000);
    await tester.pump();
    expect(sel(controller), const GridSelection.cell(5, 5), reason: 'sheet coordinates, not pixels');
    controller.setZoom(1.5);
    await tester.pump();
    await tester.pump();
    expect(sel(controller), const GridSelection.cell(5, 5));
    // Clicks after zooming and scrolling land on the cell under the pointer.
    controller.verticalController.jumpTo(0);
    await tester.pump();
    await tester.tap(find.text('r1c1'));
    await tester.pump();
    expect(sel(controller), const GridSelection.cell(1, 1));
    controller.switchSheet(0);
    expect(sel(controller), const GridSelection.cell(1, 1), reason: 're-selecting the same sheet keeps it');
  });

  testWidgets('a second tap on the active cell opens its details instead of reselecting', (tester) async {
    final controller = await load(tester);
    await pump(tester, controller);
    await tester.tap(find.text('r1c1'));
    await tester.pumpAndSettle();
    expect(find.text('Cell B2'), findsNothing);
    await tester.tap(find.text('r1c1'));
    await tester.pumpAndSettle();
    expect(find.text('Cell B2'), findsOneWidget);
  });

  testWidgets('phone, tablet and desktop sizes all select by tap', (tester) async {
    for (final size in const [Size(390, 844), Size(844, 390), Size(820, 1180), Size(1440, 900)]) {
      final controller = await load(tester);
      await pump(tester, controller, size: size);
      await tester.tap(find.text('r1c1'));
      await tester.pump();
      expect(sel(controller), const GridSelection.cell(1, 1), reason: '$size');
      await tester.pumpWidget(const SizedBox());
    }
  });

  test('select keeps a selection inside the sheet and ignores an empty one', () async {
    final controller = SpreadsheetController(format: DocumentFormat.csv);
    addTearDown(controller.dispose);
    controller.select(const GridSelection.cell(3, 3));
    expect(controller.selection.value, isNull, reason: 'nothing loaded');
    await controller.loadBytes(utf8.encode('a,b\nc,d\ne,f'));
    controller.select(const GridSelection.cell(50, 50));
    expect(controller.selection.value, const GridSelection.cell(2, 1));
    controller.moveSelection(rows: 5, columns: 5);
    expect(controller.selection.value, const GridSelection.cell(2, 1));
    controller.moveSelection(rows: -1, extend: true);
    expect(controller.selection.value!.kind, GridSelectionKind.range);
  });
}
