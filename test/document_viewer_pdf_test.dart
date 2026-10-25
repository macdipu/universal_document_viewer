import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

// In a file of its own: the PDF engine's worker is shared and answers in
// the zone of the test that started it (see document_viewer_test.dart).
void main() {
  testWidgets('opens a PDF and shows its pages, with the page in the toolbar', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DocumentViewer.file('test/fixtures/pdf/features.pdf'))),
    );
    for (var i = 0; i < 200 && find.text('Page 1 of 4').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PdfView), findsOneWidget);
    expect(find.text('Page 1 of 4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
