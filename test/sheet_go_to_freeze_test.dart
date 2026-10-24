import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/sheets.dart';
import 'package:universal_document_viewer/testing.dart';

void main() {
  Future<SpreadsheetController> load(WidgetTester tester, {ReadingPosition? position, void Function(ReadingPosition)? onPosition}) async {
    final controller = SpreadsheetController(initialPosition: position, onPositionChanged: onPosition);
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.loadXlsx(buildXlsx([
          XlsxTestSheet('Data', {for (var r = 1; r <= 200; r++) 'A$r': 'Row $r', 'D150': 'here'}),
          const XlsxTestSheet('My Notes', {'B3': 'note'}),
          const XlsxTestSheet('Frozen', {'A1': 'Head', 'A2': 1}, frozenRows: 1),
        ])));
    return controller;
  }

  Future<void> pumpGrid(WidgetTester tester, SpreadsheetController controller) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SheetGrid(controller: controller))));
    await tester.pump();
  }

  testWidgets('goTo: a cell here, a cell on another sheet (any case), a sheet by name', (tester) async {
    final controller = await load(tester);
    await pumpGrid(tester, controller);

    expect(controller.goTo('d150'), isTrue);
    await tester.pumpAndSettle();
    expect((controller.goToTarget?.row, controller.goToTarget?.column), (149, 3));
    expect(controller.isGoToTarget(149, 3), isTrue);
    expect(find.text('here'), findsOneWidget);
    expect(controller.verticalController.offset, greaterThan(0));

    expect(controller.goTo("'my notes'!b3"), isTrue);
    await tester.pumpAndSettle();
    expect(controller.activeSheetIndex, 1);
    expect((controller.goToTarget?.row, controller.goToTarget?.column), (2, 1));

    expect(controller.goTo('frozen'), isTrue);
    expect(controller.activeSheetIndex, 2);
    expect(controller.goToTarget, isNull, reason: 'a sheet switch clears the mark');

    expect(controller.goTo('Nowhere!A1'), isFalse);
    expect(controller.goTo('not a cell'), isFalse);
    expect(controller.goTo(''), isFalse);
  });

  testWidgets('the go-to dialog goes, offers sheets, and says when nothing matches', (tester) async {
    final controller = await load(tester);
    await pumpGrid(tester, controller);
    final context = tester.element(find.byType(SheetGrid));

    showGoToDialog(context, controller);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'My Notes'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ZZ');
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(find.text('No cell or sheet called "ZZ"'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'A120');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect((controller.goToTarget?.row, controller.goToTarget?.column), (119, 0));

    showGoToDialog(context, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'My Notes'));
    await tester.pumpAndSettle();
    expect(controller.activeSheetIndex, 1);
  });

  testWidgets('freezing the header row: pins it, is reported and restored', (tester) async {
    final reported = <ReadingPosition>[];
    final controller = await load(tester, onPosition: reported.add);
    await pumpGrid(tester, controller);
    expect(controller.geometry.frozenRowCount, 0);

    controller.freezeTopRow = true;
    await tester.pumpAndSettle();
    expect(controller.geometry.frozenRowCount, 1);
    expect(reported.last[PositionKeys.freezeTopRow], isTrue);
    controller.verticalController.jumpTo(2000);
    await tester.pumpAndSettle();
    expect(find.text('Row 1'), findsOneWidget, reason: 'the header row stays on screen');

    controller.switchSheet(2);
    expect(controller.sheetFreezesRows, isTrue);
    expect(controller.geometry.frozenRowCount, 1, reason: "the file's own freeze");

    final reopened = await load(tester, position: {PositionKeys.freezeTopRow: true});
    expect(reopened.freezeTopRow, isTrue);
    expect(reopened.geometry.frozenRowCount, 1);
    reopened.freezeTopRow = false;
    expect(reopened.position.containsKey(PositionKeys.freezeTopRow), isFalse);
  });
}
