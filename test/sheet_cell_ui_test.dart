import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/spreadsheet.dart';
import 'package:universal_document_viewer/testing.dart';

/// CR-SHEET-CELL-UI: density (touch and compact), the lighter selection,
/// highlighted headers, the ghost grid, `#` for numbers that don't fit,
/// scrollbars, view-only column resizing and the right-click menu.
void main() {
  Future<SpreadsheetController> load(WidgetTester tester, {List<XlsxTestSheet>? sheets, SheetDensity? density}) async {
    final controller = SpreadsheetController(density: density);
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.loadBytes(
        buildXlsx(
          sheets ??
              const [
                XlsxTestSheet('S', {
                  'A1': 'Item',
                  'B1': 'Cost',
                  'A2': 'Rent',
                  'B2': 1200,
                  'A3': 'Food',
                  'B3': 42,
                  'C3': 1234567890123,
                }),
              ],
        ),
      ),
    );
    return controller;
  }

  Future<void> pump(
    WidgetTester tester,
    SpreadsheetController controller, {
    Size size = const Size(800, 600),
    bool showScrollbars = true,
    Color? selectionColor,
    Key? boundaryKey,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundaryKey,
            child: SpreadsheetView(
              controller: controller,
              showScrollbars: showScrollbars,
              selectionColor: selectionColor,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The decoration colour of the cell showing [text].
  Color? fillOf(WidgetTester tester, String text) {
    final container = find.ancestor(of: find.text(text), matching: find.byType(Container)).first;
    final decoration = tester.widget<Container>(container).decoration as BoxDecoration;
    return decoration.color;
  }

  Future<T> onPlatform<T>(TargetPlatform platform, Future<T> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      return await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('density', () {
    test('compact rows and headers are shorter than touch ones; defaults scale from them', () {
      expect(SheetMetrics.compact.rowHeight, lessThan(SheetMetrics.touch.rowHeight));
      expect(SheetMetrics.compact.headerHeight, lessThan(SheetMetrics.touch.headerHeight));
      expect(SheetMetrics.touch.headerHeight, greaterThanOrEqualTo(44));
      expect(SheetMetrics.compact.rowHeightOf(15), 28);
      expect(SheetMetrics.touch.rowHeightOf(30), 72);
      expect(SheetMetrics.touch.columnWidthOf(8.43), SheetMetrics.touch.columnWidth);
    });

    testWidgets('a phone is touch; a desktop with a mouse is compact; both are measured on screen', (tester) async {
      final touch = await load(tester);
      await pump(tester, touch);
      expect(touch.density, SheetDensity.touch);
      expect(tester.getSize(find.text('Rent').hitTestable()).height, lessThan(SheetMetrics.touch.rowHeight));
      final touchRow = tester.getSize(find.ancestor(of: find.text('Rent'), matching: find.byType(InkWell)).first);
      expect(touchRow.height, closeTo(SheetMetrics.touch.rowHeight, 0.01));

      await onPlatform(TargetPlatform.macOS, () async {
        final desktop = await load(tester);
        await pump(tester, desktop);
        expect(desktop.density, SheetDensity.compact);
        final row = tester.getSize(find.ancestor(of: find.text('Rent'), matching: find.byType(InkWell)).first);
        expect(row.height, closeTo(SheetMetrics.compact.rowHeight, 0.01));
      });
    });

    testWidgets('a given density wins over the device', (tester) async {
      await onPlatform(TargetPlatform.macOS, () async {
        final controller = await load(tester, density: SheetDensity.touch);
        await pump(tester, controller);
        expect(controller.density, SheetDensity.touch);
        final row = tester.getSize(find.ancestor(of: find.text('Rent'), matching: find.byType(InkWell)).first);
        expect(row.height, closeTo(SheetMetrics.touch.rowHeight, 0.01));
      });
    });

    testWidgets('a desktop flips to touch rows after a finger, back to compact when the mouse moves', (tester) async {
      await onPlatform(TargetPlatform.windows, () async {
        final controller = await load(tester);
        await pump(tester, controller);
        expect(controller.density, SheetDensity.compact);

        final finger = await tester.startGesture(const Offset(300, 300), kind: PointerDeviceKind.touch);
        await finger.up();
        await tester.pump();
        expect(controller.density, SheetDensity.touch);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(10, 10));
        await mouse.moveTo(const Offset(300, 300));
        await tester.pump();
        expect(controller.density, SheetDensity.compact);
      });
    });

    testWidgets('changing density keeps the same row at the top', (tester) async {
      final controller = await load(
        tester,
        sheets: [
          XlsxTestSheet('S', {for (var r = 1; r <= 300; r++) 'A$r': 'row $r'}),
        ],
        density: SheetDensity.touch,
      );
      await pump(tester, controller, size: const Size(800, 400));
      controller.goTo(120);
      await tester.pumpAndSettle();
      expect(find.text('row 120'), findsOneWidget);
      controller.density = SheetDensity.compact;
      await tester.pumpAndSettle();
      expect(find.text('row 120'), findsOneWidget, reason: 'the top row stays in view');
    });
  });

  group('selection look', () {
    testWidgets('a selected range tints the cells over their own fill; the active cell is not tinted', (tester) async {
      final controller = await load(
        tester,
        sheets: const [
          XlsxTestSheet('S', {
            'A1': XlsxTestCell('plain'),
            'B1': XlsxTestCell('filled', fill: 'FFC000'),
            'C1': XlsxTestCell('other'),
          }),
        ],
      );
      const accent = Color(0xFF1E8E5A);
      await pump(tester, controller, selectionColor: accent);
      final base = fillOf(tester, 'filled')!;
      expect(base, const Color(0xFFFFC000));

      // A1:B1 with A1 active: B1 is tinted over its own fill.
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 1, activeRow: 0, activeColumn: 0));
      await tester.pump();
      final tinted = fillOf(tester, 'filled')!;
      expect(tinted, isNot(base), reason: 'tinted');
      expect(tinted, Color.alphaBlend(accent.withValues(alpha: 0.14), base), reason: 'over its own fill');
      expect(fillOf(tester, 'plain'), isNull, reason: 'the active cell keeps its own (no) fill');
      // With B1 active instead, B1 is left untinted and A1 is tinted.
      controller.select(const GridSelection.range(anchorRow: 0, anchorColumn: 0, activeRow: 0, activeColumn: 1));
      await tester.pump();
      expect(fillOf(tester, 'filled'), base);
      expect(fillOf(tester, 'plain'), isNotNull);
    });

    testWidgets('a single selected cell is outlined in the selection colour, not filled', (tester) async {
      final controller = await load(tester);
      const accent = Color(0xFF1E8E5A);
      await pump(tester, controller, selectionColor: accent);
      controller.select(const GridSelection.cell(1, 0));
      await tester.pump();
      final container = tester.widget<Container>(
        find.ancestor(of: find.text('Rent'), matching: find.byType(Container)).first,
      );
      expect(container.foregroundDecoration, isA<BoxDecoration>());
      final border = (container.foregroundDecoration! as BoxDecoration).border! as Border;
      expect(border.top.color, accent);
      expect(border.top.width, greaterThanOrEqualTo(2));
      expect((container.decoration! as BoxDecoration).color, isNull);
    });

    testWidgets('headers of the selected cells are highlighted with a bar, others are not', (tester) async {
      final controller = await load(tester);
      await pump(tester, controller);
      Finder bars() => find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == Theme.of(tester.element(find.byType(SpreadsheetView))).colorScheme.primary,
      );
      expect(bars(), findsNothing);
      controller.select(const GridSelection.cell(1, 1)); // B2
      await tester.pump();
      expect(bars(), findsNWidgets(2), reason: 'column B and row 2');
      controller.select(const GridSelection.row(0));
      await tester.pump();
      expect(bars(), findsOneWidget, reason: 'a row selection marks just its number');
      controller.clearSelection();
      await tester.pump();
      expect(bars(), findsNothing);
    });

    test('the default selection colours stand out from the page (3:1) in light and dark', () {
      double luminance(Color c) => c.computeLuminance();
      double ratio(Color a, Color b) {
        final x = luminance(a) + 0.05;
        final y = luminance(b) + 0.05;
        return x > y ? x / y : y / x;
      }

      for (final brightness in Brightness.values) {
        final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0057D9), brightness: brightness);
        expect(ratio(scheme.primary, scheme.surface), greaterThanOrEqualTo(3), reason: '$brightness');
      }
    });
  });

  group('ghost grid', () {
    testWidgets('faint lines continue past a small sheet', (tester) async {
      final controller = await load(tester);
      final key = GlobalKey();
      await pump(tester, controller, boundaryKey: key);
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      int pixel(int x, int y) => data.getUint32((y * image.width + x) * 4);

      // A strip well below the data (3 rows of 36 px + a 44 px header): a
      // vertical scan down the first data column must cross horizontal
      // ghost lines, i.e. not be one flat colour.
      final x = 90;
      final colours = {for (var y = 300; y < 560; y++) pixel(x, y)};
      expect(colours.length, greaterThan(1), reason: 'lines, not a blank panel');
      // And to the right of the data (columns A-C end near x=330).
      final across = {for (var xx = 400; xx < 780; xx++) pixel(xx, 100)};
      expect(across.length, greaterThan(1));
    });

    testWidgets('taps on the ghost area select nothing', (tester) async {
      final controller = await load(tester);
      await pump(tester, controller);
      await tester.tapAt(const Offset(600, 450));
      await tester.pump();
      expect(controller.selection.value, isNull);
    });
  });

  group('numbers that do not fit', () {
    testWidgets('show # instead of a shortened figure; short ones show in full; text still truncates', (tester) async {
      final controller = await load(
        tester,
        sheets: const [
          XlsxTestSheet('S', {
            'A1': XlsxTestCell(1234567, numberFormat: '#,##0.00000000'),
            'B1': 42,
            'C1': 'a very long piece of text that will not fit this cell at all',
          }),
        ],
      );
      await pump(tester, controller);
      expect(find.textContaining('1,234,567'), findsNothing);
      expect(find.textContaining('#'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.textContaining('a very long'), findsOneWidget);
      // The real value is still there for search and the cell sheet.
      controller.search('1,234,567.00000000');
      expect(controller.matches.length, 1, reason: 'search still finds the full value');
    });
  });

  group('scrollbars', () {
    testWidgets('a phone gets thumbs that fade; a desktop gets draggable ones in a gutter; both can be turned off', (
      tester,
    ) async {
      final phone = await load(tester);
      await pump(tester, phone);
      expect(find.byType(Scrollbar), findsNWidgets(2));
      expect(tester.widgetList<Scrollbar>(find.byType(Scrollbar)).every((s) => s.thumbVisibility != true), isTrue);

      await onPlatform(TargetPlatform.linux, () async {
        final desktop = await load(tester);
        await pump(tester, desktop);
        final bars = tester.widgetList<Scrollbar>(find.byType(Scrollbar)).toList();
        expect(bars.length, 2);
        expect(bars.every((s) => s.thumbVisibility == true && s.interactive == true), isTrue);
      });

      final off = await load(tester);
      await pump(tester, off, showScrollbars: false);
      expect(find.byType(Scrollbar), findsNothing);
    });
  });

  group('column resize (this view only)', () {
    Finder handle() => find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn);

    testWidgets('a mouse can drag a header edge or double-click it to fit; the file is untouched', (tester) async {
      await onPlatform(TargetPlatform.macOS, () async {
        final controller = await load(tester);
        await pump(tester, controller);
        expect(handle(), findsWidgets);
        final before = controller.geometry.columnWidth(0);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        final at = tester.getCenter(handle().first);
        await mouse.addPointer(location: at);
        await mouse.down(at);
        for (var i = 1; i <= 4; i++) {
          await mouse.moveTo(at + Offset(10.0 * i, 0));
        }
        await mouse.up();
        await tester.pump();
        expect(controller.hasColumnWidthOverride(0), isTrue);
        expect(controller.geometry.columnWidth(0), greaterThan(before), reason: 'dragged right');
        expect(controller.currentSheet!.layout.columnWidths, isEmpty, reason: 'the file model is unchanged');

        final edge = tester.getCenter(handle().first);
        await tester.tapAt(edge, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(edge, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        // "Rent" is the widest text in column A, so it fits tighter than before.
        expect(controller.geometry.columnWidth(0), lessThan(before));

        controller.setColumnWidth(0, null);
        expect(controller.hasColumnWidthOverride(0), isFalse);
        expect(controller.geometry.columnWidth(0), before);
      });
    });

    testWidgets('touch density has no resize handles (a swipe on a header must scroll)', (tester) async {
      final controller = await load(tester);
      await pump(tester, controller);
      expect(handle(), findsNothing);
    });

    testWidgets('widths the reader set are dropped when another file loads', (tester) async {
      final controller = await load(tester);
      controller.setColumnWidth(0, 200);
      expect(controller.geometry.columnWidth(0), 200);
      await tester.runAsync(
        () => controller.loadBytes(
          buildXlsx(const [
            XlsxTestSheet('S', {'A1': 'x'}),
          ]),
        ),
      );
      expect(controller.hasColumnWidthOverride(0), isFalse);
    });
  });

  group('right-click menu', () {
    testWidgets('selects the cell, offers Copy, Copy address and Details', (tester) async {
      await onPlatform(TargetPlatform.macOS, () async {
        final controller = await load(tester);
        await pump(tester, controller);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
        await mouse.addPointer(location: tester.getCenter(find.text('Rent')));
        await mouse.down(tester.getCenter(find.text('Rent')));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(controller.selection.value, const GridSelection.cell(1, 0));
        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Copy address'), findsOneWidget);
        expect(find.text('Details'), findsOneWidget);

        await tester.tap(find.text('Details'));
        await tester.pumpAndSettle();
        expect(find.text('Cell A2'), findsOneWidget);
      });
    });
  });

  group('reduced text on a zoomed-out phone', () {
    testWidgets('text never drops below 11 px', (tester) async {
      final controller = await load(tester);
      await pump(tester, controller);
      controller.setZoom(controller.minZoom);
      await tester.pump();
      final text = tester.widget<Text>(find.text('Rent'));
      expect(text.style!.fontSize, greaterThanOrEqualTo(11));
    });
  });
}
