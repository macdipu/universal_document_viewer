import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

/// CR-EXCEL-READER-AUDIT S4: workbook-wide search with Excel's Find
/// options, big workbooks searched in slices, and where a match lands
/// under frozen panes.
void main() {
  Future<SpreadsheetController> load(List<XlsxTestSheet> sheets) async {
    final controller = SpreadsheetController();
    addTearDown(controller.dispose);
    await controller.loadBytes(buildXlsx(sheets));
    return controller;
  }

  List<(int?, int, int)> places(SpreadsheetController c) => [for (final m in c.matches) (m.sheet, m.row, m.column)];

  final workbook = [
    const XlsxTestSheet('One', {
      'A1': 'Apple',
      'A2': 'apple pie',
      'A3': XlsxTestFormula('SUM(B1:B2)', cached: 7),
      'B1': 3,
      'B2': 4,
    }),
    const XlsxTestSheet('Two', {'C5': 'APPLE', 'C6': 'pineapple'}),
    const XlsxTestSheet('Gone', {'A1': 'apple'}, state: 'hidden'),
  ];

  group('options (no grid attached)', () {
    test('default: this sheet, any case, part of a cell; matches carry their sheet', () async {
      final c = await load(workbook);
      c.search('apple');
      expect(places(c), [(0, 0, 0), (0, 1, 0)]);
      expect(c.isMatch(1, 0), isTrue);
      expect(c.searchState.value.matchCount, 2);
    });

    test('match case', () async {
      final c = await load(workbook);
      c.searchOptions = const SheetSearchOptions(matchCase: true);
      c.search('Apple');
      expect(places(c), [(0, 0, 0)]);
    });

    test('whole cell', () async {
      final c = await load(workbook);
      c.searchOptions = const SheetSearchOptions(wholeCell: true);
      c.search('APPLE');
      expect(places(c), [(0, 0, 0)], reason: 'any case, but the whole cell');
    });

    test('formulas: matched by formula text instead of the value shown', () async {
      final c = await load(workbook);
      c.search('sum(');
      expect(c.matches, isEmpty, reason: 'the cell shows 7');
      c.searchOptions = const SheetSearchOptions(inFormulas: true);
      expect(places(c), [(0, 2, 0)], reason: 'changing options re-runs the search');
      c.search('7');
      expect(c.matches, isEmpty, reason: 'looks at the formula, not its value');
      c.searchOptions = const SheetSearchOptions(inFormulas: true, wholeCell: true);
      c.search('=sum(b1:b2)');
      expect(places(c), [(0, 2, 0)]);
    });

    test('all sheets: every visible sheet in order, hidden sheets skipped', () async {
      final c = await load(workbook);
      c.searchOptions = const SheetSearchOptions(allSheets: true);
      c.search('apple');
      expect(places(c), [(0, 0, 0), (0, 1, 0), (1, 4, 2), (1, 5, 2)]);
      expect(c.currentMatchIndex, 0);
    });

    test('all sheets: starts at the first match on or after the sheet on screen', () async {
      final c = await load(workbook);
      c.switchSheet(1);
      c.searchOptions = const SheetSearchOptions(allSheets: true);
      c.search('apple');
      expect(c.currentMatchIndex, 2);
      expect(c.isCurrentMatch(4, 2), isTrue);
      expect(c.isMatch(0, 0), isFalse, reason: 'highlights are per sheet');
    });

    test('a sheet switch ends a one-sheet search but keeps an all-sheets one', () async {
      final c = await load(workbook);
      c.search('apple');
      c.switchSheet(1);
      expect(c.matches, isEmpty);
      expect(c.searchQuery, isEmpty);

      c.searchOptions = const SheetSearchOptions(allSheets: true);
      c.search('apple');
      c.switchSheet(0);
      expect(c.matches.length, 4);
      expect(c.isMatch(0, 0), isTrue);
    });
  });

  group('with the grid', () {
    Future<void> pumpGrid(
      WidgetTester tester,
      SpreadsheetController controller, {
      Size size = const Size(800, 600),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SpreadsheetView(controller: controller)),
        ),
      );
      await tester.pump();
    }

    testWidgets('next match moves to the match on another sheet', (tester) async {
      final c = (await tester.runAsync(() => load(workbook)))!;
      await pumpGrid(tester, c);
      c.searchOptions = const SheetSearchOptions(allSheets: true);
      c.search('apple');
      await tester.pumpAndSettle();
      expect(c.activeSheetIndex, 0);
      c.nextMatch();
      c.nextMatch();
      await tester.pumpAndSettle();
      expect(c.activeSheetIndex, 1);
      expect(c.currentMatchIndex, 2);
      expect(find.text('APPLE'), findsOneWidget);
      c.previousMatch();
      await tester.pumpAndSettle();
      expect(c.activeSheetIndex, 0);
    });

    for (final zoom in [1.0, 1.5]) {
      testWidgets('a match far down lands below frozen rows and right of frozen columns (zoom $zoom)', (tester) async {
        final c = (await tester.runAsync(
          () => load([
            XlsxTestSheet(
              'S',
              {
                for (var r = 1; r <= 300; r++) 'A$r': 'r$r',
                for (final col in 'BCDEFGHIJKLMNOPQRST'.split('')) '${col}1': 'h$col',
                'P250': 'target',
              },
              frozenRows: 3,
              frozenColumns: 2,
            ),
          ]),
        ))!;
        await pumpGrid(tester, c);
        c.setZoom(zoom);
        await tester.pumpAndSettle();
        c.search('target');
        await tester.pumpAndSettle();
        final target = tester.getRect(find.text('target'));
        final lastFrozenRow = tester.getRect(find.text('r3'));
        final lastFrozenColumn = tester.getRect(find.text('hB'));
        expect(target.top, greaterThanOrEqualTo(lastFrozenRow.bottom));
        expect(target.left, greaterThanOrEqualTo(lastFrozenColumn.right));
        expect(target.bottom, lessThanOrEqualTo(600));
      });
    }

    testWidgets('"Freeze header row": a match does not land under the pinned row', (tester) async {
      final c = (await tester.runAsync(
        () => load([
          XlsxTestSheet('S', {for (var r = 1; r <= 300; r++) 'A$r': 'r$r', 'A250': 'target'}),
        ]),
      ))!;
      await pumpGrid(tester, c);
      c.freezeTopRow = true;
      await tester.pumpAndSettle();
      c.search('target');
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('target')).top, greaterThanOrEqualTo(tester.getRect(find.text('r1')).bottom));
    });
  });

  group('big workbooks', () {
    // 2 sheets x 1,000 rows x 150 columns = 300,000 cells: over the
    // at-once limit, so searched in slices.
    final big = [
      for (final name in ['Big1', 'Big2'])
        XlsxTestSheet(name, {
          for (var r = 1; r <= 1000; r++)
            for (var c = 0; c < 150; c++) '${_column(c)}$r': c == 149 && r == 999 ? 'needle $name' : 'x$r',
        }),
    ];

    testWidgets('searched in slices after a short delay; a newer query wins', (tester) async {
      final c = (await tester.runAsync(() => load(big)))!;
      c.searchOptions = const SheetSearchOptions(allSheets: true);
      c.search('needle');
      expect(c.isSearching, isTrue);
      expect(c.searchState.value.isSearching, isTrue);
      expect(c.matches, isEmpty, reason: 'nothing yet: the search waits for typing to pause');
      c.search('needle big2');
      await tester.pump(const Duration(milliseconds: 250));
      for (var i = 0; i < 20 && c.isSearching; i++) {
        await tester.pump();
      }
      expect(c.isSearching, isFalse);
      expect(c.searchState.value.isSearching, isFalse);
      expect(places(c), [(1, 998, 149)]);
    });

    testWidgets('clearing cancels a running search', (tester) async {
      final c = (await tester.runAsync(() => load(big)))!;
      c.searchOptions = const SheetSearchOptions(allSheets: true);
      c.search('needle');
      c.clearSearch();
      await tester.pump(const Duration(milliseconds: 250));
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      expect(c.matches, isEmpty);
      expect(c.isSearching, isFalse);
    });

    test('timing: no slice of a 300,000-cell search blocks for long', () async {
      final c = await load(big);
      c.searchOptions = const SheetSearchOptions(allSheets: true);
      final watch = Stopwatch()..start();
      var longest = Duration.zero;
      var last = watch.elapsed;
      c.search('needle');
      while (c.isSearching) {
        await Future<void>.delayed(Duration.zero);
        final now = watch.elapsed;
        if (now - last > longest) longest = now - last;
        last = now;
      }
      // ignore: avoid_print
      print('300k-cell search: total ${watch.elapsedMilliseconds} ms, longest slice ${longest.inMilliseconds} ms');
      expect(c.matches.length, 2);
      // The first gap includes the 200 ms typing delay.
      expect(longest, lessThan(const Duration(milliseconds: 400)));
    });
  });
}

String _column(int index) {
  var n = index + 1;
  var name = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    name = String.fromCharCode(65 + rem) + name;
    n = (n - 1) ~/ 26;
  }
  return name;
}
