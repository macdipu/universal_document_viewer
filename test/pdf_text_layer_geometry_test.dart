import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/engines/pdfium/pdf_types.dart';
import 'package:universal_document_viewer/src/pdf/pdf_text_layer.dart';

/// Lines of text, each character 10 wide and 12 tall, lines 20 apart.
/// Characters in [generated] (and the line breaks) get no box, as PDFium's
/// inserted spaces and line breaks do.
PdfTextLayer layerOf(List<String> lines, {bool rtl = false, bool sideways = false}) {
  final text = StringBuffer();
  final boxes = <Rect>[];
  for (var row = 0; row < lines.length; row++) {
    final line = lines[row];
    for (var col = 0; col < line.length; col++) {
      text.write(line[col]);
      final along = rtl ? (line.length - 1 - col) * 10.0 : col * 10.0;
      final across = row * 20.0;
      boxes.add(
        line[col] == ' '
            ? Rect.zero
            : sideways
            ? Rect.fromLTWH(across, along, 12, 10)
            : Rect.fromLTWH(along, across, 10, 12),
      );
    }
    if (row < lines.length - 1) {
      text.write('\r\n');
      boxes
        ..add(Rect.zero)
        ..add(Rect.zero);
    }
  }
  return PdfTextLayer(PdfPageText(text.toString(), boxes, sideways: sideways));
}

void main() {
  group('lines and carets', () {
    final layer = layerOf(['Hello world', 'Second line']);

    test('a page with no text is empty', () {
      final empty = PdfTextLayer(const PdfPageText('', []));
      expect(empty.isEmpty, isTrue);
      expect(empty.caretAt(const Offset(5, 5)), 0);
      expect(empty.charAt(const Offset(5, 5)), isNull);
      expect(empty.rects(0, 5), isEmpty);
      expect(empty.textOf(0, 5), isEmpty);
    });

    test('charAt finds the character under the point', () {
      expect(layer.charAt(const Offset(3, 5)), 0);
      expect(layer.charAt(const Offset(43, 5)), 4);
      // Second line starts after "Hello world\r\n" (13 units).
      expect(layer.charAt(const Offset(3, 25)), 13);
    });

    test('caretAt lands before or after a character by which half is hit', () {
      expect(layer.caretAt(const Offset(2, 5)), 0);
      expect(layer.caretAt(const Offset(8, 5)), 1);
      expect(layer.caretAt(const Offset(14, 5)), 1);
      expect(layer.caretAt(const Offset(16, 5)), 2);
    });

    test('a point past either end of a line clamps to that line', () {
      expect(layer.caretAt(const Offset(-50, 5)), 0);
      expect(layer.caretAt(const Offset(500, 5)), 11);
      expect(layer.caretAt(const Offset(500, 25)), 13 + 11);
    });

    test('a point above or below all lines uses the nearest line', () {
      expect(layer.caretAt(const Offset(2, -100)), 0);
      expect(layer.caretAt(const Offset(500, 300)), 24);
    });

    test('between two lines it picks the closer one', () {
      expect(layer.caretAt(const Offset(2, 14)), 0);
      expect(layer.caretAt(const Offset(2, 19)), 13);
    });
  });

  group('words and lines', () {
    final layer = layerOf(['Hello world, ok', 'Second line']);

    test('a word is a run of letters and digits', () {
      expect(layer.wordAt(1), (0, 5));
      expect(layer.wordAt(8), (6, 11));
    });

    test('a punctuation mark is a word by itself', () {
      expect(layer.wordAt(11), (11, 12));
    });

    test('a word does not run across a line break', () {
      final broken = layerOf(['abc', 'def']);
      expect(broken.wordAt(1), (0, 3));
      expect(broken.wordAt(6), (5, 8));
    });

    test('lineAt excludes the generated line break', () {
      expect(layer.lineAt(3), (0, 15));
      expect(layer.lineAt(20), (17, 28));
    });
  });

  group('rects and text', () {
    final layer = layerOf(['Hello world', 'Second line']);

    test('a range on one line is one rectangle', () {
      expect(layer.rects(0, 5), [const Rect.fromLTRB(0, 0, 50, 12)]);
    });

    test('a range over two lines is a rectangle per line', () {
      final rects = layer.rects(6, 13 + 6);
      expect(rects, hasLength(2));
      expect(rects[0], const Rect.fromLTRB(60, 0, 110, 12));
      expect(rects[1], const Rect.fromLTRB(0, 20, 60, 32));
    });

    test('out of range offsets are clamped, an empty range has no rects', () {
      expect(layer.rects(-5, 0), isEmpty);
      expect(layer.rects(5, 5), isEmpty);
      expect(layer.rects(0, 9999), hasLength(2));
    });

    test('textOf turns PDFium line breaks into newlines', () {
      expect(layer.textOf(0, 24), 'Hello world\nSecond line');
      expect(layer.textOf(6, 11), 'world');
      expect(layer.textOf(11, 11), isEmpty);
    });
  });

  group('right-to-left and sideways pages', () {
    test('right-to-left text: the caret follows the reading direction', () {
      final layer = layerOf(['abcd'], rtl: true);
      // 'a' is the rightmost character (x 30..40); before it is the right side.
      expect(layer.caretAt(const Offset(38, 5)), 0);
      expect(layer.caretAt(const Offset(32, 5)), 1);
      expect(layer.caretAt(const Offset(-20, 5)), 4);
    });

    test('a sideways page reads down the screen', () {
      final layer = layerOf(['abcd', 'efgh'], sideways: true);
      expect(layer.charAt(const Offset(5, 25)), 2);
      expect(layer.caretAt(const Offset(5, 4)), 0);
      expect(layer.caretAt(const Offset(5, 500)), 4);
      expect(layer.rects(0, 4), [const Rect.fromLTRB(0, 0, 12, 40)]);
    });
  });
}
