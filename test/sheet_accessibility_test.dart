import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

/// CR-EXCEL-READER-AUDIT S6: what a screen reader says for cells, a
/// visible keyboard focus ring, reduced motion, 44 dp headers.
void main() {
  Future<SpreadsheetController> pump(WidgetTester tester) async {
    final controller = SpreadsheetController();
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.loadBytes(
        buildXlsx([
          XlsxTestSheet(
            'S',
            {
              'A1': 'Item',
              'B1': 'Cost',
              'A2': 'Rent',
              'B2': 40,
              'B3': const XlsxTestFormula('SUM(B2:B2)', cached: 40),
              for (var r = 4; r <= 200; r++) 'A$r': 'row $r',
            },
            comments: {'A2': (author: 'me', text: 'paid')},
          ),
        ]),
      ),
    );
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: SpreadsheetView(controller: controller)),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('cells say address, value, formula, note and selection', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = await pump(tester);
    expect(find.bySemanticsLabel('B2, value 40'), findsOneWidget);
    expect(find.bySemanticsLabel('B3, value 40, formula'), findsOneWidget);
    expect(find.bySemanticsLabel('A2, value Rent, has note'), findsOneWidget);
    expect(find.bySemanticsLabel('A3, empty'), findsOneWidget);

    controller.select(const GridSelection.cell(1, 1));
    await tester.pump();
    expect(find.bySemanticsLabel('B2, value 40, selected'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('B2, value 40, selected')),
      matchesSemantics(
        isSelected: true,
        hasSelectedState: true,
        isButton: true,
        hasTapAction: true,
        hasLongPressAction: true,
        label: 'B2, value 40, selected',
        hasEnabledState: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('a visible ring shows while the keyboard drives the grid, and goes away for touch', (tester) async {
    await pump(tester);
    bool ring() => tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).any((box) {
      final decoration = box.decoration;
      return box.position == DecorationPosition.foreground &&
          decoration is BoxDecoration &&
          decoration.border is Border &&
          (decoration.border! as Border).top.width == 2 &&
          decoration.border!.isUniform &&
          (decoration.border! as Border).top.color ==
              Theme.of(tester.element(find.byType(SpreadsheetView))).colorScheme.primary;
    });

    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // Focus the grid by selecting a cell with a tap, then use the keyboard.
    await tester.tap(find.text('Rent'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(ring(), isTrue);

    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    await tester.pump();
    expect(ring(), isFalse);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('with reduced motion a jump is instant; otherwise it animates', (tester) async {
    final controller = await pump(tester);
    final scroll = controller.verticalController;

    controller.jumpToCell(const CellMatch(row: 150, column: 0));
    await tester.pump();
    final animating = scroll.offset;
    await tester.pumpAndSettle();
    expect(animating, lessThan(scroll.offset), reason: 'still on its way after one frame');

    scroll.jumpTo(0);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    controller.jumpToCell(const CellMatch(row: 150, column: 0));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    final instant = scroll.offset;
    await tester.pumpAndSettle();
    expect(scroll.offset, instant, reason: 'no animation left to run');
  });

  testWidgets('touch: column headers are at least 44 dp tall; row headers 40 wide', (tester) async {
    await pump(tester);
    final header = find.ancestor(of: find.text('A'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(header).height, greaterThanOrEqualTo(44));
    final rowHeader = find.ancestor(of: find.text('1'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(rowHeader).width, greaterThanOrEqualTo(40));
    expect(SpreadsheetController.headerHeight, greaterThanOrEqualTo(44));
  });
}
