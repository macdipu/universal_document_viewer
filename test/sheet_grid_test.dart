import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/sheets.dart';
import 'package:universal_document_viewer/testing.dart';

void main() {
  Future<SpreadsheetController> load(WidgetTester tester) async {
    final controller = SpreadsheetController();
    await tester.runAsync(() => controller.loadXlsx(File('test/fixtures/sheets/features.xlsx').readAsBytesSync()));
    return controller;
  }

  Future<void> pumpGrid(WidgetTester tester, SpreadsheetController controller) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SheetGrid(controller: controller))));
    await tester.pump();
  }

  testWidgets('hidden rows and columns are left out; widths come from the file', (tester) async {
    final controller = await load(tester);
    await pumpGrid(tester, controller);
    // Row 9 and column G are hidden.
    expect(find.bySemanticsLabel('Row 8'), findsOneWidget);
    expect(find.bySemanticsLabel('Row 9'), findsNothing);
    expect(find.bySemanticsLabel('Column F'), findsOneWidget);
    expect(find.bySemanticsLabel('Column G'), findsNothing);
    // Column A is 20 characters wide, B the default.
    final a = tester.getSize(find.bySemanticsLabel('Column A')).width;
    final b = tester.getSize(find.bySemanticsLabel('Column B')).width;
    expect(b, SpreadsheetController.cellWidth);
    expect(a, closeTo(SheetGeometry.columnWidthOf(20), 0.5));
  });

  testWidgets('a merged area shows its value once, across its columns', (tester) async {
    final controller = await load(tester);
    await pumpGrid(tester, controller);
    final wide = find.text('wide');
    expect(wide, findsOneWidget);
    final cell = find.ancestor(of: wide, matching: find.byType(InkWell)).first;
    expect(tester.getSize(cell).width, closeTo(3 * SpreadsheetController.cellWidth, 0.5));
    // A1:C10's merge would cross the frozen column, so it stays one cell.
    final merged = find.ancestor(of: find.text('merged'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(merged).width, closeTo(SheetGeometry.columnWidthOf(20), 0.5));
  });

  testWidgets('a link to another sheet switches to it', (tester) async {
    final controller = await load(tester);
    expect(controller.sheetNames, ['Summary', 'Later']);
    expect(controller.openInternalLink('Later!B3'), isTrue);
    expect(controller.activeSheetIndex, 1);
    expect(controller.openInternalLink("'No such sheet'!A1"), isFalse);
    expect(controller.openInternalLink('B3'), isTrue);
  });

  testWidgets('tapping a cell shows its formula and note; data bars and borders draw', (tester) async {
    final controller = SpreadsheetController();
    await tester.runAsync(() => controller.loadXlsx(buildXlsx([
          const XlsxTestSheet(
            'S',
            {
              'A1': 2,
              'B1': XlsxTestXml('<f>A1*21</f><v>42</v>'),
              'C1': XlsxTestCell('Boxed', border: 'thick'),
            },
            comments: {'B1': (author: 'Rina', text: 'Answer, roughly')},
            afterSheetData: '<conditionalFormatting sqref="A1"><cfRule type="dataBar" priority="1"><dataBar>'
                '<cfvo type="num" val="0"/><cfvo type="num" val="4"/><color rgb="FF638EC6"/></dataBar></cfRule>'
                '</conditionalFormatting>',
          ),
        ])));
    await pumpGrid(tester, controller);

    expect(find.byType(FractionallySizedBox), findsOneWidget, reason: "A1's data bar");
    final boxed = tester.widget<Container>(
      find.ancestor(of: find.text('Boxed'), matching: find.byType(Container)).first,
    );
    expect(((boxed.decoration! as BoxDecoration).border! as Border).top.width, closeTo(1.8, 1e-9));

    await tester.tap(find.text('42'));
    await tester.pumpAndSettle();
    expect(find.text('Cell B1'), findsOneWidget);
    expect(find.text('Formula'), findsOneWidget);
    expect(find.text('=A1*21'), findsOneWidget);
    expect(find.text('Note from Rina'), findsOneWidget);
    expect(find.text('Answer, roughly'), findsOneWidget);
    Navigator.of(tester.element(find.text('Cell B1'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Boxed'));
    await tester.pumpAndSettle();
    expect(find.text('Formula'), findsNothing, reason: 'a plain cell has no formula line');
  });
}
