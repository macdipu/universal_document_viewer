import 'dart:math' as math;
import 'dart:ui';

import '../engines/pdfium/pdf_types.dart';

/// A line of a page's text: the characters [first] to [last] (inclusive)
/// that have a box, drawn along one line.
class _TextLine {
  _TextLine(this.first, this.bounds) : last = first;

  final int first;
  int last;
  Rect bounds;

  /// +1 when the characters advance towards larger x (or y, on a sideways
  /// page); -1 when they run the other way (right-to-left text).
  int direction = 1;
}

/// A page's text laid out for selecting: which character is under a point,
/// where a word or a line starts and ends, and the rectangles to paint for
/// a range of text.
///
/// Built from [PdfPageText], whose boxes are in page points from the
/// top-left of the page as displayed. Offsets in and out are positions in
/// [text]: a "caret" is the gap before a character (0 to [length]), a
/// "char" the character itself.
class PdfTextLayer {
  /// Lays out [page].
  PdfTextLayer(PdfPageText page) : text = page.text, boxes = page.boxes, sideways = page.sideways {
    _build();
  }

  /// The page's text, one UTF-16 unit per character, with the line breaks
  /// PDFium generates.
  final String text;

  /// One box per unit of [text]; empty for generated characters.
  final List<Rect> boxes;

  /// Whether lines run up or down the screen (a page turned 90 or 270
  /// degrees).
  final bool sideways;

  final List<_TextLine> _lines = [];

  /// How many units of [text] there are.
  int get length => math.min(text.length, boxes.length);

  /// Whether the page has no selectable text (blank, or a scan).
  bool get isEmpty => _lines.isEmpty;

  static bool _visible(Rect box) => box.width > 0 || box.height > 0;

  double _crossStart(Rect r) => sideways ? r.left : r.top;
  double _crossEnd(Rect r) => sideways ? r.right : r.bottom;
  double _mainCenter(Rect r) => sideways ? r.center.dy : r.center.dx;

  void _build() {
    _TextLine? line;
    for (var i = 0; i < length; i++) {
      final box = boxes[i];
      if (!_visible(box)) continue;
      if (line != null && _sameLine(line.bounds, box)) {
        line.last = i;
        line.bounds = line.bounds.expandToInclude(box);
      } else {
        line = _TextLine(i, box);
        _lines.add(line);
      }
    }
    for (final l in _lines) {
      final delta = _mainCenter(boxes[l.last]) - _mainCenter(boxes[l.first]);
      l.direction = delta < 0 ? -1 : 1;
    }
  }

  /// Whether [box] sits on the line whose boxes span [bounds]: they overlap
  /// across the line by over half the smaller one.
  bool _sameLine(Rect bounds, Rect box) {
    final overlap = math.min(_crossEnd(bounds), _crossEnd(box)) - math.max(_crossStart(bounds), _crossStart(box));
    final smaller = math.min(_crossEnd(bounds) - _crossStart(bounds), _crossEnd(box) - _crossStart(box));
    return overlap > 0 && overlap >= smaller * 0.5;
  }

  /// The line nearest [point]: across the line first, then along it, so
  /// that of two columns the nearer one wins.
  _TextLine? _nearestLine(Offset point) {
    _TextLine? best;
    var bestCross = double.infinity;
    var bestMain = double.infinity;
    for (final line in _lines) {
      final b = line.bounds;
      final cross = sideways ? _gap(point.dx, b.left, b.right) : _gap(point.dy, b.top, b.bottom);
      final main = sideways ? _gap(point.dy, b.top, b.bottom) : _gap(point.dx, b.left, b.right);
      final better = cross < bestCross - 0.5 || (cross <= bestCross + 0.5 && main < bestMain);
      if (better) {
        best = line;
        bestCross = cross;
        bestMain = main;
      }
    }
    return best;
  }

  static double _gap(double v, double lo, double hi) => v < lo ? lo - v : (v > hi ? v - hi : 0);

  /// The character nearest [point] on the nearest line, with whether
  /// [point] is past its middle in the line's reading direction; null when
  /// the page has no text.
  (int index, bool after)? _nearest(Offset point) {
    final line = _nearestLine(point);
    if (line == null) return null;
    final main = sideways ? point.dy : point.dx;
    var best = line.first;
    var bestDistance = double.infinity;
    for (var i = line.first; i <= line.last; i++) {
      if (!_visible(boxes[i])) continue;
      final distance = (main - _mainCenter(boxes[i])).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return (best, (main - _mainCenter(boxes[best])) * line.direction > 0);
  }

  /// The caret (0 to [length]) nearest [point]: the gap a drag at that
  /// point would put an end of the selection in. 0 for a page with no
  /// text.
  int caretAt(Offset point) {
    final nearest = _nearest(point);
    if (nearest == null) return 0;
    final (index, after) = nearest;
    return after ? index + 1 : index;
  }

  /// Whether [point] is on a character (give or take [slop] points), for
  /// showing a text cursor.
  bool isOverText(Offset point, {double slop = 1}) {
    for (final line in _lines) {
      if (!line.bounds.inflate(slop).contains(point)) continue;
      for (var i = line.first; i <= line.last; i++) {
        if (_visible(boxes[i]) && boxes[i].inflate(slop).contains(point)) return true;
      }
    }
    return false;
  }

  /// The character nearest [point]; null when the page has no text.
  int? charAt(Offset point) => _nearest(point)?.$1;

  static int _kind(int unit) {
    if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0) return 0;
    final isWord =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A) ||
        unit == 0x5F ||
        unit >= 0x80;
    return isWord ? 1 : 2;
  }

  /// The word around character [index], as `(start, end)` with [end]
  /// exclusive: a run of letters and digits, of spaces, or one mark.
  (int, int) wordAt(int index) {
    if (length == 0) return (0, 0);
    final at = index.clamp(0, length - 1);
    final kind = _kind(text.codeUnitAt(at));
    if (kind == 2) return (at, at + 1);
    var start = at;
    var end = at + 1;
    while (start > 0 && _kind(text.codeUnitAt(start - 1)) == kind && _sameLineAs(at, start - 1)) {
      start--;
    }
    while (end < length && _kind(text.codeUnitAt(end)) == kind && _sameLineAs(at, end)) {
      end++;
    }
    return (start, end);
  }

  /// Whether characters [a] and [b] are on the same line (a generated
  /// character, which has no box, counts as being on the line it ends).
  bool _sameLineAs(int a, int b) {
    final la = _lineOf(a);
    final lb = _lineOf(b);
    return la != null && la == lb;
  }

  _TextLine? _lineOf(int index) {
    _TextLine? found;
    for (final line in _lines) {
      if (line.first > index) break;
      found = line;
    }
    if (found == null) return null;
    // A generated character past the line's last visible one (its line
    // break) belongs to that line; a generated character between two lines
    // too.
    return found;
  }

  /// The line around character [index], as `(start, end)` with [end]
  /// exclusive and without the line break.
  (int, int) lineAt(int index) {
    final line = _lineOf(index.clamp(0, math.max(0, length - 1)));
    if (line == null) return (0, 0);
    return (line.first, line.last + 1);
  }

  /// The rectangles covering characters [start] to [end] (exclusive), one
  /// per line, in page points.
  List<Rect> rects(int start, int end) {
    final from = start.clamp(0, length);
    final to = end.clamp(0, length);
    final result = <Rect>[];
    if (to <= from) return result;
    for (final line in _lines) {
      if (line.last < from) continue;
      if (line.first >= to) break;
      Rect? union;
      for (var i = math.max(from, line.first); i <= math.min(to - 1, line.last); i++) {
        final box = boxes[i];
        if (!_visible(box)) continue;
        union = union == null ? box : union.expandToInclude(box);
      }
      if (union != null) result.add(union);
    }
    return result;
  }

  /// The text of characters [start] to [end] (exclusive), with each line
  /// break as `\n`.
  String textOf(int start, int end) {
    final from = start.clamp(0, length);
    final to = end.clamp(0, length);
    if (to <= from) return '';
    return text.substring(from, to).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
}
