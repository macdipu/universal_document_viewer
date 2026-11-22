import 'dart:ui';

import '../engines/pdfium/pdf_types.dart';
import '../ocr/text_recognizer.dart';

/// A recognised line of text on a page, in page points from the top-left.
class PdfOcrLine {
  /// A [text] line occupying [rect].
  const PdfOcrLine(this.text, this.rect);

  /// What the line says.
  final String text;

  /// Where it is on the page, in page points.
  final Rect rect;
}

/// Where a recognizer's lines are on the page: [result] was read from an
/// image of [imageSize] pixels covering the whole page, [pageSize] points.
List<PdfOcrLine> ocrLinesOnPage(OcrResult result, {required Size imageSize, required Size pageSize}) {
  final sx = pageSize.width / imageSize.width;
  final sy = pageSize.height / imageSize.height;
  return [
    for (final line in result.lines)
      if (line.text.trim().isNotEmpty)
        PdfOcrLine(
          line.text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
          Rect.fromLTRB(line.rect.left * sx, line.rect.top * sy, line.rect.right * sx, line.rect.bottom * sy),
        ),
  ];
}

/// [native] text plus [lines] that PDFium did not already read.
///
/// A recognised line mostly covered by the page's own text boxes is the
/// same words twice (a page with text and pictures is read whole), so it is
/// dropped. The rest follow the page's text, a line each. A recognizer
/// gives a box per line, not per character, so a line's characters share its
/// width equally.
PdfPageText mergeOcr(PdfPageText native, List<PdfOcrLine> lines) {
  final visible = [
    for (final box in native.boxes)
      if (box.width > 0 || box.height > 0) box,
  ];
  bool alreadyThere(Rect rect) {
    final area = rect.width * rect.height;
    if (area <= 0) return true;
    var covered = 0.0;
    for (final box in visible) {
      final overlap = box.intersect(rect);
      if (overlap.width > 0 && overlap.height > 0) covered += overlap.width * overlap.height;
    }
    return covered / area > 0.4;
  }

  final text = StringBuffer(native.text);
  final boxes = [...native.boxes];
  var first = native.text.isEmpty;
  for (final line in lines) {
    if (alreadyThere(line.rect)) continue;
    if (!first) {
      text.write('\r\n');
      boxes
        ..add(Rect.zero)
        ..add(Rect.zero);
    }
    first = false;
    final count = line.text.length;
    final step = line.rect.width / count;
    for (var i = 0; i < count; i++) {
      text.writeCharCode(line.text.codeUnitAt(i));
      boxes.add(
        Rect.fromLTRB(line.rect.left + i * step, line.rect.top, line.rect.left + (i + 1) * step, line.rect.bottom),
      );
    }
  }
  return PdfPageText(text.toString(), boxes, sideways: visible.isNotEmpty && native.sideways);
}
