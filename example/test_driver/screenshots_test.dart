import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer_example/library.dart';
import 'package:universal_document_viewer_example/main.dart';

/// Takes the README and pub.dev screenshots on a phone emulator:
///
///     flutter drive -d <device> --driver test_driver/integration_test.dart \
///         --target test_driver/screenshots_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screenshots', (tester) async {
    final library = await DocumentLibrary.load();
    library.forgetPositions();
    await tester.pumpWidget(ExampleApp(library: library));
    await binding.convertFlutterSurfaceToImage();

    /// Pumps until nothing on screen is loading any more.
    Future<void> settle() async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      do {
        await tester.pump(const Duration(milliseconds: 200));
      } while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty && DateTime.now().isBefore(end));
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> shoot(String name) async {
      await settle();
      await binding.takeScreenshot(name);
    }

    Future<void> back() async {
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    /// Opens [name] from its card, or from the card's menu with [reader].
    Future<void> open(String name, {String? reader}) async {
      final card = find.ancestor(of: find.text(name), matching: find.byType(Card));
      await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      if (reader == null) {
        await tester.tap(card);
      } else {
        await tester.tap(find.descendant(of: card, matching: find.byIcon(Icons.more_vert)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(reader));
      }
      await tester.pumpAndSettle();
      await settle();
    }

    // Read a little of each, so the home screen shows where they resume.
    await open('guide.pdf');
    await shoot('2_pdf');
    await tester.dragFrom(tester.getCenter(find.byType(DocumentViewer)), const Offset(0, -2400));
    await settle();
    await back();

    await open('report.docx', reader: 'Open in the Word reader');
    await shoot('3_word');
    await back();

    await open('sales.xlsx', reader: 'Open in the sheet reader');
    // Zoomed out a little, so every column of the first sheet shows.
    await tester.tap(find.byIcon(Icons.zoom_out_rounded));
    await tester.tap(find.byIcon(Icons.zoom_out_rounded));
    await shoot('4_sheet');
    await back();

    await open('deck.pptx');
    await tester.dragFrom(tester.getCenter(find.byType(DocumentViewer)), const Offset(-300, 0));
    await settle();
    await back();

    await tester.fling(find.byType(CustomScrollView), const Offset(0, 3000), 5000);
    await tester.pumpAndSettle();
    await shoot('1_home');
  });
}
