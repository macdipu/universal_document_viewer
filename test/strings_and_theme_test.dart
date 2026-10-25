import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

class _Shouting extends DocumentViewerStrings {
  const _Shouting();

  @override
  String loadError(DocumentLoadError error) => 'NOPE: ${error.name}';

  @override
  String location(DocumentLocation location) => 'L${location.current}/${location.count}';
}

void main() {
  testWidgets('DocumentViewerStringsScope replaces the built-in text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentViewerStringsScope(
          strings: const _Shouting(),
          child: Scaffold(
            body: DocumentViewer.bytes(Uint8List.fromList(utf8.encode('one\ntwo')), format: DocumentFormat.text),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('L1/2'), findsOneWidget, reason: 'the toolbar uses the app\'s wording');

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentViewerStringsScope(
          strings: const _Shouting(),
          child: Scaffold(body: DocumentViewer.bytes(Uint8List.fromList([0, 1, 2]), format: DocumentFormat.text)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('NOPE: corrupted'), findsOneWidget);
  });

  testWidgets('DocumentViewerTheme colours the search matches', (tester) async {
    const match = Color(0xFF00FF00);
    const current = Color(0xFFFF0000);
    final controller = PlainTextController();
    addTearDown(controller.dispose);
    await controller.loadBytes(Uint8List.fromList(utf8.encode('apple apple')));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const [DocumentViewerTheme(matchBackground: match, currentMatchBackground: current)],
        ),
        home: Scaffold(body: PlainTextView(controller: controller)),
      ),
    );
    controller.search('apple');
    await tester.pump();
    final spans = <TextSpan>[];
    tester.widget<RichText>(find.byType(RichText).first).text.visitChildren((span) {
      if (span is TextSpan && span.text == 'apple') spans.add(span);
      return true;
    });
    expect([for (final span in spans) span.style?.backgroundColor], [current, match]);
  });
}
