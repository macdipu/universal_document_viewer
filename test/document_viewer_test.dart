import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/testing.dart';

/// Lets the file read and parse finish in real time, then builds.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('kit-viewer-'));
  tearDown(() async => dir.delete(recursive: true));

  Future<void> pumpViewer(WidgetTester tester, String name, List<int> bytes) async {
    final path = '${dir.path}/$name';
    await tester.runAsync(() => File(path).writeAsBytes(bytes));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentViewer.file(path))));
    await settle(tester);
  }

  testWidgets('opens text', (tester) async {
    await pumpViewer(tester, 'notes.txt', 'first line\nsecond line'.codeUnits);
    expect(find.text('second line'), findsOneWidget);
  });

  testWidgets('opens CSV in the sheet grid', (tester) async {
    await pumpViewer(tester, 'data.csv', 'Name,Score\nAlice,97\n'.codeUnits);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
  });

  testWidgets('opens PowerPoint with slide navigation', (tester) async {
    await pumpViewer(tester, 'deck.pptx', buildPptx([titleShape('Hello'), titleShape('Bye')]));
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('says when a type is not supported', (tester) async {
    await pumpViewer(tester, 'old.ppt', [1, 2, 3]);
    expect(find.text('This file type is not supported.'), findsOneWidget);
  });

  testWidgets('says when a file is damaged', (tester) async {
    await pumpViewer(tester, 'broken.xlsx', [1, 2, 3]);
    expect(find.text('This document may be damaged or incomplete.'), findsOneWidget);
  });

  testWidgets('refuses an Office file over the size ceiling before reading it', (tester) async {
    for (final name in ['huge.docx', 'huge.xlsx', 'huge.pptx']) {
      final path = '${dir.path}/$name';
      await tester.runAsync(() async {
        final handle = await File(path).open(mode: FileMode.write);
        await handle.truncate(ZipSafetyGuard.maxFileBytes + 1); // Sparse: nothing is written.
        await handle.close();
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentViewer.file(path))));
      await settle(tester);
      expect(find.text('This document is too large to open.'), findsOneWidget, reason: name);
    }
  });

  // One test, as the PDF engine's worker is shared and answers in the zone
  // of the test that started it.
  testWidgets('an encrypted PDF is password protected, and opens with passwordProvider\'s password', (tester) async {
    /// Lets the PDF engine's isolate work, in real time, until [done] (and
    /// a little longer, for what follows it) or a few seconds pass.
    Future<void> pumpPdf(Widget viewer, bool Function() done) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: viewer)));
      var after = 10;
      for (var i = 0; i < 200 && after > 0; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
        if (done()) after--;
      }
    }

    const path = 'test/fixtures/pdf/encrypted.pdf';
    const message = 'This document is password protected.';
    await pumpPdf(DocumentViewer.file(path), () => find.text(message).evaluate().isNotEmpty);
    expect(find.text(message), findsOneWidget);

    var asked = 0;
    DocumentLoadError? failed;
    await pumpPdf(
      DocumentViewer.file(
        path,
        key: const ValueKey('with password'),
        passwordProvider: () async => asked++ == 0 ? 'secret' : null,
        errorBuilder: (context, error) {
          failed = error;
          return const SizedBox();
        },
      ),
      () => asked > 0,
    );
    expect(asked, 1);
    expect(failed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reopens when the path changes', (tester) async {
    await pumpViewer(tester, 'a.txt', 'from a'.codeUnits);
    final second = '${dir.path}/b.txt';
    await tester.runAsync(() => File(second).writeAsBytes('from b'.codeUnits));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentViewer.file(second))));
    await settle(tester);
    expect(find.text('from b'), findsOneWidget);
    expect(find.text('from a'), findsNothing);
  });

  testWidgets('a load that outlives the viewer is dropped', (tester) async {
    final path = '${dir.path}/late.txt';
    await tester.runAsync(() => File(path).writeAsBytes('late'.codeUnits));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DocumentViewer.file(path))));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
