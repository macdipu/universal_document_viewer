import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/text.dart';

void main() {
  Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

  test('splits text into lines, decoding UTF-8', () {
    final doc = TextDocumentController()..load(text('héllo\nworld'));
    expect(doc.error, isNull);
    expect(doc.lines, ['héllo', 'world']);
  });

  test('falls back to Latin-1 for non-UTF-8 bytes', () {
    final doc = TextDocumentController()..load(Uint8List.fromList([0x63, 0x61, 0x66, 0xE9]));
    expect(doc.lines, ['café']);
  });

  test('drops a UTF-8 byte order mark and decodes UTF-16 by its mark', () {
    expect(decodeTextBytes(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('Name,Age')])), 'Name,Age');
    final little = TextDocumentController()
      ..load(Uint8List.fromList([0xFF, 0xFE, 0x68, 0, 0xE9, 0, 0x0A, 0, 0x34, 0x6C]));
    expect(little.error, isNull);
    expect(little.lines, ['hé', '水']);
    final big = TextDocumentController()..load(Uint8List.fromList([0xFE, 0xFF, 0, 0x68, 0, 0x69]));
    expect(big.error, isNull);
    expect(big.lines, ['hi']);
  });

  test('refuses binary content as corrupted', () {
    final doc = TextDocumentController()..load(Uint8List.fromList([0x50, 0x4B, 0x00, 0x01]));
    expect(doc.error, DocumentLoadError.corrupted);
  });

  test('restores and reports the scroll offset', () {
    ReadingPosition? reported;
    final doc = TextDocumentController(
      initialPosition: {PositionKeys.scrollOffset: 120.5},
      onPositionChanged: (p) => reported = p,
    );
    expect(doc.initialScrollOffset, 120.5);
    doc.onScrolled(40);
    expect(reported, {PositionKeys.scrollOffset: 40.0});
  });

  test('reports the line at the top once the view measures lines', () {
    ReadingPosition? reported;
    final doc = TextDocumentController(onPositionChanged: (p) => reported = p)
      ..lineAtOffsetResolver = (offset) => offset ~/ 20;
    doc.onScrolled(410);
    expect(reported, {PositionKeys.scrollOffset: 410.0, PositionKeys.line: 20});
  });

  group('TextLineMetrics.lineAt', () {
    TextLineMetrics metrics({required bool wrap}) => TextLineMetrics(
          lines: [for (var i = 0; i < 50; i++) i.isEven ? 'short' : 'a longer line ' * 8],
          style: const TextStyle(fontSize: 10),
          textScaler: TextScaler.noScaling,
          contentWidth: 200,
          wrap: wrap,
          verticalPadding: 4,
        );

    test('is the inverse of offsetOf, wrapped or not', () {
      for (final wrap in [true, false]) {
        final m = metrics(wrap: wrap);
        for (final line in [0, 1, 7, 30, 49]) {
          expect(m.lineAt(m.offsetOf(line)), line, reason: 'wrap $wrap, line $line');
          expect(m.lineAt(m.offsetOf(line) + 1), line, reason: 'wrap $wrap, inside line $line');
        }
        expect(m.lineAt(-5), 0);
        expect(m.lineAt(1e9), 49);
      }
    });
  });

  test('search matches lines in any case and cycles', () {
    final doc = TextDocumentController()..load(text('Alpha\nbeta\nALPHA again'));
    doc.search('alpha');
    expect(doc.matches, [0, 2]);
    expect(doc.currentMatch, 0);
    doc.nextMatch();
    expect(doc.currentMatch, 1);
    doc.nextMatch();
    expect(doc.currentMatch, 0);
    doc.previousMatch();
    expect(doc.currentMatch, 1);
    doc.clearSearch();
    expect(doc.matches, isEmpty);
  });
}
