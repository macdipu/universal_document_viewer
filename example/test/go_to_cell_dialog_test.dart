import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer_example/widgets/go_to_cell_dialog.dart';

void main() {
  testWidgets('the go-to dialog goes, offers sheets, and says when nothing matches', (tester) async {
    final controller = SpreadsheetController(format: DocumentFormat.excel);
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.loadBytes(
        buildXlsx([
          XlsxTestSheet('Data', {for (var r = 1; r <= 200; r++) 'A$r': 'Row $r'}),
          const XlsxTestSheet('My Notes', {'B3': 'note'}),
        ]),
      ),
    );
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SpreadsheetView(controller: controller)),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(SpreadsheetView));

    showGoToCellDialog(context, controller);
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

    showGoToCellDialog(context, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'My Notes'));
    await tester.pumpAndSettle();
    expect(controller.activeSheetIndex, 1);
  });
}
