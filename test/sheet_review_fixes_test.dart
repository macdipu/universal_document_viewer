import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/sheets.dart';
import 'package:universal_document_viewer/src/engines/sheets/formula_references.dart';
import 'package:universal_document_viewer/testing.dart';

/// Regressions for the pre-release review of the spreadsheet code
/// (CR-OWN-ENGINES, 2026-10-24).
void main() {
  Worksheet sheetOf(XlsxTestSheet sheet, {List<String> dxfs = const []}) =>
      XlsxReader.read(buildXlsx([sheet], dxfs: dxfs)).sheets.single;

  group('number formats', () {
    test('a fraction with many ? digits is quick and exact', () {
      final watch = Stopwatch()..start();
      expect(const NumberFormat('# ?????????/?????????').format(3.14159), '3 14159/100000');
      expect(const NumberFormat('# ???/???').format(3.14159), '3 16/113');
      expect(const NumberFormat('# ?/?').format(0.5), '1/2');
      expect(watch.elapsedMilliseconds, lessThan(200));
    });

    test('an empty section hides the value', () {
      expect(const NumberFormat(';;;').format(5), '');
      expect(const NumberFormat('0;;').format(-5), '');
      expect(const NumberFormat('0;;').format(5), '5');
    });

    test('more than 20 decimals and dates outside Excel\'s range don\'t throw', () {
      expect(const NumberFormat('0.000000000000000000000').format(1.5), startsWith('1.5'));
      expect(const NumberFormat('yyyy-mm-dd').format(1e9), '#####');
      expect(const NumberFormat('yyyy-mm-dd').format(-3), '#####');
      expect(const NumberFormat('yyyy-mm-dd').format(45000), '2023-03-15');
    });
  });

  group('hostile cell references', () {
    test('cells outside the grid, row 0 and column-less refs are ignored', () {
      final sheet = sheetOf(const XlsxTestSheet('S', {
        'A1': 1,
        'ZZZZZZZ1': XlsxTestXml('<v>2</v>'),
      }, afterSheetData: '<conditionalFormatting sqref="A0:A2"><cfRule type="containsBlanks" dxfId="0" priority="1"/>'
          '</conditionalFormatting>'), dxfs: ['<dxf><fill><patternFill><bgColor rgb="FFFF0000"/></patternFill></fill></dxf>']);
      expect(sheet.rows.single.length, 1);
    });

    test('far-off rows and comments don\'t allocate rows up to them', () {
      final bytes = buildXlsx([
        const XlsxTestSheet('S', {'A1': 1}, comments: {'A2000000000': (author: 'x', text: 'far')}),
      ]);
      final sheet = XlsxReader.read(bytes).sheets.single;
      expect(sheet.rows.length, 1);
      expect(sheet.comments, isEmpty);
    });

    test('scattered far-right cells stay within the cell budget', () {
      final watch = Stopwatch()..start();
      final sheet = sheetOf(XlsxTestSheet('S', {for (var r = 1; r <= 2000; r++) 'XFD$r': r}));
      final slots = sheet.rows.fold(0, (sum, row) => sum + row.length);
      expect(slots, lessThanOrEqualTo(10000000));
      expect(watch.elapsed.inSeconds, lessThan(10));
    });

    test('NaN, Infinity and hex are not numbers', () {
      final sheet = sheetOf(const XlsxTestSheet('S', {
        'A1': XlsxTestXml('<v>NaN</v>'),
        'B1': XlsxTestXml('<v>Infinity</v>'),
        'C1': XlsxTestXml('<v>0x1F</v>'),
        'D1': XlsxTestXml('<v>-1.5e3</v>'),
      }));
      expect([for (final cell in sheet.rows.single) cell?.value], [null, null, null, isA<NumberValue>()]);
    });
  });

  test('cellIs notEqual with an operand it can\'t work out matches nothing', () {
    final sheet = sheetOf(
      const XlsxTestSheet('S', {'A1': 1, 'A2': 2}, afterSheetData: r'<conditionalFormatting sqref="A1:A2">'
          r'<cfRule type="cellIs" dxfId="0" priority="1" operator="notEqual"><formula>SUM($B$1:$B$3)</formula></cfRule>'
          '</conditionalFormatting>'),
      dxfs: ['<dxf><font><b/></font></dxf>'],
    );
    expect(sheet.rows.map((row) => row.single!.style.bold), [false, false]);
  });

  test('structured references are not shifted as cells', () {
    expect(shiftFormula('SUM(Sales[Q1])+[@Q2]+A1', 1, 0), 'SUM(Sales[Q1])+[@Q2]+A2');
    expect(shiftFormula("Tbl[[#This Row],['[Q1']]]*B2", 0, 1), "Tbl[[#This Row],['[Q1']]]*C2");
    expect(shiftFormula('[Book1.xlsx]Sheet1!A1', 1, 0), '[Book1.xlsx]Sheet1!A2');
  });

  group('go to and sheet switches', () {
    Future<SpreadsheetController> load(WidgetTester tester, {ReadingPosition? position, ValueChanged<ReadingPosition>? onPosition}) async {
      final controller = SpreadsheetController(initialPosition: position, onPositionChanged: onPosition);
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.loadXlsx(buildXlsx([
            XlsxTestSheet('One', {for (var r = 1; r <= 300; r++) 'A$r': r, 'AB12': 'far'}),
            XlsxTestSheet('Two', {for (var r = 1; r <= 300; r++) 'A$r': r}),
          ])));
      return controller;
    }

    testWidgets('columns past Z, ranges and in-sheet links work', (tester) async {
      final controller = await load(tester);
      expect(controller.goTo('AB12'), isTrue);
      expect((controller.goToTarget?.row, controller.goToTarget?.column), (11, 27));
      expect(controller.goTo('B3:C4'), isTrue);
      expect((controller.goToTarget?.row, controller.goToTarget?.column), (2, 1));
      expect(controller.openInternalLink('AB12'), isTrue);
      expect(controller.openInternalLink(r'Two!$AA$1'), isTrue);
      expect(controller.goTo('A2000000'), isFalse);
    });

    testWidgets('the offsets restored at open don\'t follow to another sheet', (tester) async {
      final reported = <ReadingPosition>[];
      final controller = await load(
        tester,
        position: {PositionKeys.sheetIndex: 0, PositionKeys.verticalOffset: 1000.0},
        onPosition: reported.add,
      );
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            // As the app does: each sheet gets its own grid.
            builder: (context, _) => SheetGrid(key: ValueKey(controller.activeSheetIndex), controller: controller),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(controller.verticalController.offset, closeTo(1000, 1));

      controller.switchSheet(1);
      expect(reported.last[PositionKeys.verticalOffset], 0.0, reason: "the old sheet's offset isn't reported for the new");
      await tester.pumpAndSettle();
      expect(controller.verticalController.offset, 0);
    });
  });
}

