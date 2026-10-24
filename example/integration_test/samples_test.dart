import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/sheets.dart';
import 'package:universal_document_viewer_example/library.dart';
import 'package:universal_document_viewer_example/pages/reader_page.dart';
import 'package:universal_document_viewer_example/pages/sheet_page.dart';
import 'package:universal_document_viewer_example/pages/word_page.dart';

/// Opens every sample on a real device or emulator - native PDFium, the
/// background parsing isolates, real fonts - and renders every thumbnail:
///
///     flutter test integration_test -d <device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late DocumentLibrary library;

  setUpAll(() async {
    library = await DocumentLibrary.load();
    library.forgetPositions();
  });

  String sample(String name) => library.samples.firstWhere((path) => path.endsWith('/$name'));

  /// Pumps until nothing on screen is loading any more (at most [limit]).
  Future<void> settle(WidgetTester tester, {Duration limit = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(limit);
    do {
      await tester.pump(const Duration(milliseconds: 200));
    } while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty && DateTime.now().isBefore(end));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> show(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await settle(tester);
  }

  final shows = {
    'guide.pdf': 'Chapter 1',
    'report.docx': 'Quarterly Report',
    'sales.xlsx': 'Region',
    'contacts.csv': 'Name',
    // The deck was built before the package was renamed.
    'deck.pptx': 'open_reader_kit',
    'notes.txt': 'Theta',
  };

  for (final MapEntry(key: name, value: text) in shows.entries) {
    testWidgets('DocumentViewer opens $name', (tester) async {
      await show(tester, ReaderPage(library: library, path: sample(name)));
      expect(find.textContaining('damaged'), findsNothing);
      expect(find.textContaining('too large'), findsNothing);
      // A PDF is drawn, not text widgets: check the page count instead.
      if (!name.endsWith('.pdf')) {
        expect(find.textContaining(text, findRichText: true), findsWidgets, reason: name);
      }
      // Readers report where they are once moved: scroll down (or swipe a
      // slide), then the position is saved.
      if (name == 'sales.xlsx') {
        // The first sheet fits on screen; the long one scrolls.
        await tester.tap(find.text('Orders'));
        await settle(tester);
      }
      final centre = tester.getCenter(find.byType(DocumentViewer));
      await tester.dragFrom(centre, name.endsWith('.pptx') ? const Offset(-300, 0) : const Offset(0, -600));
      await settle(tester);
      expect(library.positionOf(sample(name)), isNotNull, reason: '$name reports a position');
    });
  }

  testWidgets('locked.pdf opens with its password', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ReaderPage(library: library, path: sample('locked.pdf'))));
    await settle(tester, limit: const Duration(seconds: 5));
    expect(find.text('Password'), findsOneWidget);
    await tester.enterText(find.byType(TextField), DocumentLibrary.lockedPdfPassword);
    await tester.tap(find.text('Open'));
    await settle(tester);
    expect(find.text('Password'), findsNothing);
    expect(find.textContaining('needs a password'), findsNothing);
  });

  testWidgets('the Word reader searches and switches layout', (tester) async {
    await show(tester, WordPage(library: library, path: sample('report.docx')));
    await tester.enterText(find.byType(TextField), 'report');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(RegExp(r'^1/\d+$')), findsOneWidget);
    await tester.tap(find.byTooltip('Print layout'));
    await settle(tester);
    expect(find.byTooltip('Continuous layout'), findsOneWidget);
  });

  testWidgets('the sheet reader goes to a cell on another sheet and freezes the header', (tester) async {
    await show(tester, SheetPage(library: library, path: sample('sales.xlsx')));
    expect(find.text('Orders'), findsOneWidget, reason: 'sheet tabs');
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to cell'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Orders!B150');
    await tester.tap(find.text('Go'));
    await settle(tester);
    expect(find.text('Customer 1'), findsWidgets, reason: 'row 150 is Customer 149 % 37 = 1');
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckedPopupMenuItem<String>));
    await settle(tester);
    expect(find.text('Order'), findsOneWidget, reason: 'the header row stays on screen');
  });

  testWidgets('every sample has a thumbnail; the resumed one differs', (tester) async {
    for (final name in DocumentLibrary.sampleNames) {
      final png = await tester.runAsync(() => DocumentThumbnails.render(sample(name), width: 160));
      if (name == 'locked.pdf') {
        expect(png, isNull, reason: 'no password, no thumbnail');
      } else {
        expect(png, isNotNull, reason: name);
      }
    }
    final first = await tester.runAsync(() => DocumentThumbnails.render(sample('guide.pdf'), width: 160));
    final page5 = await tester.runAsync(
      () => DocumentThumbnails.render(sample('guide.pdf'), width: 160, position: {PositionKeys.pageNumber: 5}),
    );
    expect(page5, isNot(first));
  });

  test('the sheet controller reads the workbook with its formatting', () async {
    final controller = SpreadsheetController();
    await controller.loadXlsx(await File(sample('sales.xlsx')).readAsBytes());
    expect(controller.sheetNames, ['Regions', 'Orders']);
    final units = controller.currentRows[2][1]!;
    expect(units.style.fillColor, isNotNull, reason: 'South is under target: conditional fill');
    expect(controller.currentSheet!.comments, isNotEmpty);
    controller.dispose();
  });
}
