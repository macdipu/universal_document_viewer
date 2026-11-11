import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/spreadsheet.dart';
import 'package:universal_document_viewer/testing.dart';

/// Copy and the selection's statistics (CR-EXCEL-READER-AUDIT S2).
void main() {
  Future<SpreadsheetController> loadCsv(WidgetTester tester, String csv) async {
    final controller = SpreadsheetController(format: DocumentFormat.csv);
    await tester.runAsync(() => controller.loadBytes(utf8.encode(csv)));
    return controller;
  }

  Future<void> pump(WidgetTester tester, SpreadsheetController controller) async {
    tester.view.physicalSize = const Size(1440, 900);
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

  /// Records what the app puts on the clipboard; [fail] makes it refuse.
  List<String> mockClipboard(WidgetTester tester, {bool fail = false}) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (fail) throw PlatformException(code: 'denied');
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return copied;
  }

  group('selectedText', () {
    test('a cell reads as it shows; a range is tab- and newline-separated', () async {
      final controller = SpreadsheetController(format: DocumentFormat.csv);
      await controller.loadBytes(utf8.encode('a,b,c\nd,e,f\ng,h,i'));
      expect(controller.selectedText(), isNull, reason: 'nothing selected');
      controller.select(const GridSelection.cell(1, 1));
      expect(controller.selectedText(), 'e');
      controller.select(const GridSelection.range(anchorRow: 2, anchorColumn: 2, activeRow: 0, activeColumn: 1));
      expect(controller.selectedText(), 'b\tc\ne\tf\nh\ti');
      controller.select(const GridSelection.row(1));
      expect(controller.selectedText(), 'd\te\tf');
      controller.select(const GridSelection.column(0));
      expect(controller.selectedText(), 'a\nd\ng');
      controller.selectAll();
      expect(controller.selectedText(), 'a\tb\tc\nd\te\tf\ng\th\ti');
    });

    test('a cell with a tab, line break or quote is quoted so pasting keeps the grid', () async {
      final controller = SpreadsheetController(format: DocumentFormat.csv);
      await controller.loadBytes(utf8.encode('"x\ty","line1\nline2","say ""hi"""\nplain,b,c'));
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 1, activeColumn: 2));
      expect(controller.selectedText(), '"x\ty"\t"line1\nline2"\t"say ""hi"""\nplain\tb\tc');
      controller.select(const GridSelection.cell(0, 1));
      expect(controller.selectedText(), 'line1\nline2', reason: 'one cell is copied as it reads');
    });

    test('a column drops trailing blank rows; an explicit range keeps its shape', () async {
      final controller = SpreadsheetController(format: DocumentFormat.csv);
      await controller.loadBytes(utf8.encode('a,x\nb,\n,\n,y'));
      controller.select(const GridSelection.column(0));
      expect(controller.selectedText(), 'a\nb');
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 3, activeColumn: 0));
      expect(controller.selectedText(), 'a\nb\n\n');
    });
  });

  testWidgets('Ctrl+C copies the selected range as TSV and says so', (tester) async {
    final controller = await loadCsv(tester, 'a,b,c\nd,e,f\ng,h,i');
    final copied = mockClipboard(tester);
    await pump(tester, controller);
    controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 1, activeColumn: 1));
    await tester.pump();
    await tester.tap(find.text('a'));
    await tester.pump();
    controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 1, activeColumn: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, ['a\tb\nd\te']);
    expect(find.text('A1:B2 copied'), findsOneWidget);
  });

  testWidgets('Cmd+C works too, and does nothing without a selection', (tester) async {
    final controller = await loadCsv(tester, 'a,b\nc,d');
    final copied = mockClipboard(tester);
    await pump(tester, controller);
    await tester.tap(find.text('a'));
    await tester.pump();
    controller.clearSelection();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copied, isEmpty);
    await tester.tap(find.text('d'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copied, ['d']);
  });

  testWidgets('the bar copies the selection and its address', (tester) async {
    final controller = await loadCsv(tester, 'a,b\nc,d');
    final copied = mockClipboard(tester);
    await pump(tester, controller);
    controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 1, activeColumn: 1));
    await tester.pump();
    await tester.tap(find.byTooltip('Copy a1:b2'));
    await tester.pump();
    await tester.tap(find.byTooltip('Copy address'));
    await tester.pump();
    expect(copied, ['a\tb\nc\td', 'A1:B2']);
  });

  testWidgets('a refused copy says so instead of claiming success', (tester) async {
    final controller = await loadCsv(tester, 'a,b\nc,d');
    final copied = mockClipboard(tester, fail: true);
    await pump(tester, controller);
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, isEmpty);
    expect(find.textContaining('Could not copy'), findsOneWidget);
    expect(find.textContaining('copied'), findsNothing);
  });

  group('statistics', () {
    Future<SpreadsheetController> stats(WidgetTester tester) async {
      final controller = SpreadsheetController();
      await tester.runAsync(
        () => controller.loadBytes(
          buildXlsx([
            XlsxTestSheet('S', {
              'A1': 10,
              'A2': 20,
              'A3': 'x',
              'B1': const XlsxTestCell(0.1, numberFormat: '0%'),
              'B2': const XlsxTestCell(0.2, numberFormat: '0%'),
              'C1': const XlsxTestCell(45000, numberFormat: 'yyyy-mm-dd'),
              'C2': const XlsxTestCell(45001, numberFormat: 'yyyy-mm-dd'),
            }),
          ]),
        ),
      );
      return controller;
    }

    testWidgets('numbers give count, sum, average, min and max; text is counted but not added', (tester) async {
      final controller = await stats(tester);
      await pump(tester, controller);
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 2, activeColumn: 0));
      await tester.pump();
      expect(find.textContaining('Count 3'), findsOneWidget);
      expect(find.textContaining('Numbers 2'), findsOneWidget, reason: 'a total is not mistaken for everything');
      expect(find.textContaining('Sum 30'), findsOneWidget);
      expect(find.textContaining('Avg 15'), findsOneWidget);
      expect(find.textContaining('Min 10'), findsOneWidget);
      expect(find.textContaining('Max 20'), findsOneWidget);
    });

    testWidgets('percentages are totalled as percentages, not as 0.3', (tester) async {
      final controller = await stats(tester);
      await pump(tester, controller);
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 1, activeRow: 1, activeColumn: 1));
      await tester.pump();
      expect(find.textContaining('Sum 30%'), findsOneWidget);
      expect(find.textContaining('Min 10%'), findsOneWidget);
    });

    testWidgets('dates are counted but never added', (tester) async {
      final controller = await stats(tester);
      await pump(tester, controller);
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 2, activeRow: 1, activeColumn: 2));
      await tester.pump();
      expect(find.textContaining('Count 2'), findsOneWidget);
      expect(find.textContaining('Sum'), findsNothing);
      expect(find.textContaining('Min'), findsNothing);
    });

    testWidgets('a range over the cap is sized but not totalled', (tester) async {
      final controller = await loadCsv(
        tester,
        [for (var r = 0; r < 400; r++) List.filled(300, '1').join(',')].join('\n'),
      );
      await pump(tester, controller);
      controller.selectAll();
      await tester.pump();
      expect(find.textContaining('400R × 300C'), findsOneWidget);
      expect(find.textContaining('Too many cells to total'), findsOneWidget);
      expect(find.textContaining('Sum'), findsNothing);
    });
  });
}
