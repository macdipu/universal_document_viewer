import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../engines/pdfium/pdf_engine.dart';
import '../engines/pdfium/pdf_types.dart';
import 'pdf_ocr.dart';
import 'pdf_text_layer.dart';

/// A place between two characters of a PDF: [offset] characters into page
/// [page] (from 0). [end] stands for "after the last character".
@immutable
class PdfCaret implements Comparable<PdfCaret> {
  /// The gap [offset] characters into [page].
  const PdfCaret(this.page, this.offset);

  /// After the last character of a page, whatever its length.
  static const end = 1 << 30;

  /// 0-based page index.
  final int page;

  /// Characters before the caret on the page.
  final int offset;

  @override
  int compareTo(PdfCaret other) => page != other.page ? page.compareTo(other.page) : offset.compareTo(other.offset);

  @override
  bool operator ==(Object other) => other is PdfCaret && other.page == page && other.offset == offset;

  @override
  int get hashCode => Object.hash(page, offset);

  @override
  String toString() => 'PdfCaret($page, ${offset == end ? 'end' : offset})';
}

/// A stretch of one PDF page's text: characters [start] to [end] (exclusive)
/// of the page's text as PDFium reads it. [text] is what those characters
/// said when the range was made, so an app that saved the range can tell
/// whether it still fits the document.
@immutable
class PdfTextRange {
  /// Characters [start] to [end] of page [page] (0-based), which read [text].
  const PdfTextRange({required this.page, required this.start, required this.end, required this.text});

  /// 0-based page index.
  final int page;

  /// Offset of the first character in the page's text.
  final int start;

  /// Offset just past the last character.
  final int end;

  /// The words in the range, line breaks as `\n`.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is PdfTextRange && other.page == page && other.start == start && other.end == end && other.text == text;

  @override
  int get hashCode => Object.hash(page, start, end, text);

  @override
  String toString() => 'PdfTextRange(page $page, $start-$end, "$text")';
}

/// A coloured mark over a [PdfTextRange], painted by [PdfView] under the
/// selection. The package draws it; keeping highlights between sessions is
/// the app's job (see [PdfController.selectedRanges] and
/// [PdfController.setHighlights]).
@immutable
class PdfHighlight {
  /// Marks [range] in [color].
  const PdfHighlight({required this.range, required this.color});

  /// What is marked.
  final PdfTextRange range;

  /// The mark's colour; it is drawn translucent over the text.
  final Color color;

  @override
  bool operator ==(Object other) => other is PdfHighlight && other.range == range && other.color == color;

  @override
  int get hashCode => Object.hash(range, color);
}

/// What is selected in a PDF, and the text of the pages it needs.
///
/// A selection runs from an [anchor] (where the drag began) to a [focus]
/// (where it is now), over any number of pages. It lives here, not in the
/// pages' widgets, so it survives pages scrolling out of view.
class PdfSelectionController extends ChangeNotifier {
  /// Reads text through [document]; [pageCount] says how many pages there
  /// are.
  PdfSelectionController({required PdfiumDocument? Function() document, required int Function() pageCount})
    : _document = document,
      _pageCount = pageCount;

  final PdfiumDocument? Function() _document;
  final int Function() _pageCount;

  /// How many pages' text is kept.
  static const maxCachedLayers = 24;

  final _layers = <int, PdfTextLayer>{};
  final _ocr = <int, List<PdfOcrLine>>{};
  final _hasNativeText = <int, bool>{};
  final _loading = <int, Future<PdfTextLayer?>>{};
  int _generation = 0;

  PdfCaret? _anchor;
  PdfCaret? _focus;
  var _highlights = const <PdfHighlight>[];

  /// Where the selection began; null when nothing is selected.
  PdfCaret? get anchor => _anchor;

  /// Where the selection ends now; null when nothing is selected.
  PdfCaret? get focus => _focus;

  /// Whether a non-empty range is selected.
  bool get hasSelection => _anchor != null && _focus != null && _anchor != _focus;

  /// The start of the selection in reading order.
  PdfCaret? get start => hasSelection ? (_anchor!.compareTo(_focus!) <= 0 ? _anchor : _focus) : null;

  /// The end of the selection in reading order.
  PdfCaret? get endCaret => hasSelection ? (_anchor!.compareTo(_focus!) <= 0 ? _focus : _anchor) : null;

  /// The text of [page] if it has been read.
  PdfTextLayer? layerOf(int page) {
    final layer = _layers.remove(page);
    if (layer != null) _layers[page] = layer;
    return layer;
  }

  /// Reads the text of [page] (once, however many ask), then calls
  /// listeners; null when the page can't be read.
  Future<PdfTextLayer?> loadLayer(int page) {
    final cached = layerOf(page);
    if (cached != null) return Future.value(cached);
    final generation = _generation;
    return _loading[page] ??= () async {
      try {
        final document = _document();
        if (document == null || page < 0 || page >= document.pageCount) return null;
        final native = await document.text(page);
        if (generation != _generation) return null;
        _hasNativeText[page] = native.text.trim().isNotEmpty;
        final recognised = _ocr[page];
        final layer = PdfTextLayer(recognised == null ? native : mergeOcr(native, recognised));
        _layers[page] = layer;
        while (_layers.length > maxCachedLayers) {
          _layers.remove(_layers.keys.first);
        }
        if (rangeOn(page) != null || _highlights.any((h) => h.range.page == page)) notifyListeners();
        return layer;
      } catch (_) {
        return null;
      } finally {
        if (generation == _generation) _loading.remove(page);
      }
    }();
  }

  /// Whether PDFium found text on [page] itself (reads the page if need
  /// be); false for a scan, and for a page that is blank.
  Future<bool> hasNativeText(int page) async {
    final known = _hasNativeText[page];
    if (known != null) return known;
    await loadLayer(page);
    return _hasNativeText[page] ?? false;
  }

  /// Whether [page] has recognised text.
  bool hasOcr(int page) => _ocr.containsKey(page);

  /// Records the lines read from [page] by OCR; the page's text then
  /// includes them wherever PDFium had none.
  void setOcr(int page, List<PdfOcrLine> lines) {
    _ocr[page] = lines;
    _layers.remove(page);
    notifyListeners();
  }

  /// The marks to paint, in the order given.
  List<PdfHighlight> get highlights => _highlights;

  /// Shows [highlights] (replacing any shown before) and reads the text of
  /// their pages so they can be drawn.
  void setHighlights(List<PdfHighlight> highlights) {
    _highlights = List.unmodifiable(highlights);
    for (final page in {for (final h in highlights) h.range.page}) {
      unawaited(loadLayer(page));
    }
    notifyListeners();
  }

  /// The marks on [page], as rectangles in page points, each with its colour.
  List<(Rect, Color)> highlightRectsOn(int page) {
    final layer = _layers[page];
    if (layer == null) return const [];
    return [
      for (final h in _highlights)
        if (h.range.page == page)
          for (final rect in layer.rects(h.range.start, h.range.end)) (rect, h.color),
    ];
  }

  /// The selection as ranges, one per page it covers (empty when nothing is
  /// selected), after reading the pages it needs. For making a highlight or
  /// saving a place.
  Future<List<PdfTextRange>> selectedRanges() async {
    final from = start;
    final to = endCaret;
    if (from == null || to == null) return const [];
    final ranges = <PdfTextRange>[];
    for (var page = from.page; page <= to.page; page++) {
      final layer = await loadLayer(page);
      final range = rangeOn(page);
      if (layer == null || range == null) continue;
      final text = layer.textOf(range.$1, range.$2);
      if (text.trim().isEmpty) continue;
      ranges.add(PdfTextRange(page: page, start: range.$1, end: range.$2, text: text));
    }
    return ranges;
  }

  /// Selects from [anchor] to [focus].
  void select(PdfCaret anchor, PdfCaret focus) {
    if (_anchor == anchor && _focus == focus) return;
    _anchor = anchor;
    _focus = focus;
    notifyListeners();
  }

  /// Moves the end of the selection, keeping its anchor.
  void moveFocus(PdfCaret focus) {
    final anchor = _anchor;
    if (anchor == null) return;
    select(anchor, focus);
  }

  /// Selects every character of every page.
  void selectAll() {
    final count = _pageCount();
    if (count == 0) return;
    select(const PdfCaret(0, 0), PdfCaret(count - 1, PdfCaret.end));
  }

  /// Clears the selection.
  void clear() {
    if (_anchor == null && _focus == null) return;
    _anchor = null;
    _focus = null;
    notifyListeners();
  }

  /// Forgets the text and boxes read so far, which no longer match the pages (they were turned), but
  /// keeps the highlights. The selection is cleared, as its boxes are gone.
  void invalidateGeometry() {
    _generation++;
    _layers.clear();
    _loading.clear();
    _ocr.clear();
    _hasNativeText.clear();
    clear();
    notifyListeners();
  }

  /// Forgets everything, for another document.
  void reset() {
    _generation++;
    _layers.clear();
    _loading.clear();
    _ocr.clear();
    _hasNativeText.clear();
    _highlights = const [];
    clear();
  }

  /// The selected characters of [page] as `(start, end)`, [end] exclusive;
  /// null when the selection doesn't touch the page, or its text isn't
  /// read yet and the range depends on it.
  (int, int)? rangeOn(int page) {
    final from = start;
    final to = endCaret;
    if (from == null || to == null || page < from.page || page > to.page) return null;
    final layer = _layers[page];
    final length = layer?.length;
    final begin = page == from.page ? from.offset : 0;
    final finish = page == to.page ? to.offset : length;
    if (finish == null) return null;
    final clampedEnd = length == null ? finish : finish.clamp(0, length);
    final clampedBegin = length == null ? begin : begin.clamp(0, length);
    return clampedEnd > clampedBegin ? (clampedBegin, clampedEnd) : null;
  }

  /// The rectangles to paint over [page] (page points), one per line.
  List<Rect> rectsOn(int page) {
    final range = rangeOn(page);
    final layer = _layers[page];
    if (range == null || layer == null) return const [];
    return layer.rects(range.$1, range.$2);
  }

  /// The selected text of the pages already read, pages separated by a
  /// blank line; null when nothing is selected.
  String? currentText() {
    final from = start;
    final to = endCaret;
    if (from == null || to == null) return null;
    final parts = <String>[];
    for (var page = from.page; page <= to.page; page++) {
      final range = rangeOn(page);
      final layer = _layers[page];
      if (range == null || layer == null) continue;
      final text = layer.textOf(range.$1, range.$2);
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// [currentText] after reading every page the selection covers.
  Future<String?> resolveText() async {
    final from = start;
    final to = endCaret;
    if (from == null || to == null) return null;
    // Read in chunks that fit the cache, so a select-all on a long
    // document can't be evicted before it is joined.
    final parts = <String>[];
    for (var page = from.page; page <= to.page; page++) {
      final layer = await loadLayer(page);
      final range = rangeOn(page);
      if (layer == null || range == null) continue;
      final text = layer.textOf(range.$1, range.$2);
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// Every page's text joined by blank lines, for "copy all".
  Future<String> allText() async {
    final parts = <String>[];
    for (var page = 0; page < _pageCount(); page++) {
      final layer = await loadLayer(page);
      if (layer == null || layer.isEmpty) continue;
      final text = layer.textOf(0, layer.length);
      if (text.trim().isNotEmpty) parts.add(text);
    }
    return parts.join('\n\n');
  }

  /// The page's text with its boxes, as read.
  @visibleForTesting
  void debugPut(int page, PdfPageText text) => _layers[page] = PdfTextLayer(text);
}
