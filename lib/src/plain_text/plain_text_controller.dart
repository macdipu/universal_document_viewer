import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/document_controller.dart';
import '../common/reader_contract.dart';
import '../common/text_decoding.dart';

/// One occurrence of a search in a plain-text document: on line [line]
/// (from 0), starting at character [start].
@immutable
class TextMatch {
  /// An occurrence on [line] at [start].
  const TextMatch(this.line, this.start);

  /// The line, from 0.
  final int line;

  /// Where the match starts in the line.
  final int start;

  @override
  bool operator ==(Object other) => other is TextMatch && other.line == line && other.start == start;

  @override
  int get hashCode => Object.hash(line, start);
}

/// Loads a plain-text document for [PlainTextView]: its lines, line wrap,
/// zoom, search and the scroll position.
///
/// Text is decoded as UTF-8, or after a UTF-16 byte order mark, falling
/// back to Latin-1. The [position] is `{scroll_offset, line}` (`line`, the
/// top visible line, once the view has measured its lines).
class PlainTextController extends DocumentController {
  /// Reopens at the scroll offset saved in [initialPosition], if any.
  PlainTextController({ReadingPosition? initialPosition, super.onPositionChanged, bool wrap = true})
    : _wrap = wrap,
      initialScrollOffset = switch (initialPosition?[PositionKeys.scrollOffset]) {
        final num offset when offset > 0 => offset.toDouble(),
        _ => 0,
      };

  /// Above this size a file is refused rather than read into memory in one
  /// pass.
  static const int maxBytes = 20 * 1024 * 1024;

  @override
  int get maxFileBytes => maxBytes;

  /// Fallback line height for jumps before the view has measured real
  /// lines.
  static const double _approxLineHeight = 20;

  /// Where the view scrolls to once laid out (from the saved position).
  /// Settable until then, for an app that reads the saved position after
  /// creating the controller.
  double initialScrollOffset;

  /// The view's vertical scrolling.
  @internal
  final scrollController = ScrollController();

  /// Scroll offset of a line's top, measured by the view against the real
  /// font, width and wrap. Null until the view lays out.
  @internal
  double Function(int lineIndex)? lineOffsetResolver;

  /// The line at a scroll offset: the inverse of [lineOffsetResolver], set
  /// by the view alongside it.
  @internal
  int Function(double offset)? lineAtOffsetResolver;

  List<String> _lines = const [];

  /// The document's lines.
  List<String> get lines => _lines;

  /// Checks [bytes] look like text, then decodes them into lines.
  @override
  Future<void> loadBytes(Uint8List bytes) async {
    markLoading();
    if (bytes.length > maxBytes) {
      markFailed(DocumentLoadError.tooLarge);
    } else if (looksBinary(bytes)) {
      markFailed(DocumentLoadError.corrupted);
    } else {
      _lines = decodeTextBytes(bytes).split('\n');
      _updateLocation(0);
      markReady();
    }
  }

  /// A cheap heuristic, not a real content-type sniffer: a NUL byte, or a
  /// high proportion of non-whitespace control bytes in a leading sample,
  /// is treated as "not text" (e.g. a binary file renamed `.txt`). UTF-16
  /// text with a byte order mark is text, whatever its NUL bytes.
  static bool looksBinary(Uint8List bytes) {
    if (bytes.isEmpty || hasUtf16Bom(bytes)) return false;
    final sampleSize = bytes.length < 8000 ? bytes.length : 8000;
    var controlCount = 0;
    for (var i = 0; i < sampleSize; i++) {
      final b = bytes[i];
      if (b == 0) return true;
      final isCommonWhitespace = b == 0x09 || b == 0x0A || b == 0x0D;
      if (!isCommonWhitespace && b < 0x20) controlCount++;
    }
    return controlCount / sampleSize > 0.05;
  }

  // ---- Where the reader is

  int _topLine = 0;
  bool _topLineKnown = false;
  double? _offset;

  void _updateLocation(int topLine) {
    _topLine = topLine;
    updateLocation(DocumentLocation(current: topLine + 1, count: _lines.length, unit: DocumentUnit.line));
  }

  /// `line` is there once the view has measured its lines.
  @override
  ReadingPosition get position => {
    PositionKeys.scrollOffset: _offset ?? initialScrollOffset,
    if (_topLineKnown) PositionKeys.line: _topLine,
  };

  /// [PlainTextView] reports every scroll here.
  @internal
  void onScrolled(double offset) {
    _offset = offset;
    if (lineAtOffsetResolver?.call(offset) case final line?) {
      _topLineKnown = true;
      _updateLocation(line);
    }
    reportPosition();
  }

  /// Scrolls line [number] (from 1) to the top.
  @override
  void goTo(int number) {
    if (_lines.isEmpty) return;
    _jumpToLine(number.clamp(1, _lines.length) - 1, animate: false);
  }

  void _jumpToLine(int lineIndex, {bool animate = true}) {
    if (!scrollController.hasClients) return;
    final offset = lineOffsetResolver?.call(lineIndex) ?? lineIndex * _approxLineHeight;
    final target = offset.clamp(0.0, scrollController.position.maxScrollExtent);
    if (animate) {
      scrollController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
    } else {
      scrollController.jumpTo(target);
    }
  }

  // ---- Wrap

  bool _wrap;

  /// Whether long lines wrap; when false each line scrolls sideways.
  bool get wrap => _wrap;

  set wrap(bool value) {
    if (value == _wrap) return;
    _wrap = value;
    notifyListeners();
  }

  // ---- Zoom

  double _zoom = 1;

  /// Scales [PlainTextView.fontSize]: the text reflows at the new size.
  @override
  double get zoom => _zoom;

  @override
  double get minZoom => 0.625;

  @override
  double get maxZoom => 2;

  @override
  double get zoomStep => 0.125;

  @override
  void setZoom(double zoom) {
    zoom = zoom.clamp(minZoom, maxZoom);
    if (zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
  }

  // ---- Search

  String _query = '';

  /// The text being searched for; empty when there's no search.
  String get searchQuery => _query;

  List<TextMatch> _matches = const [];

  /// Every occurrence of [searchQuery], in order.
  List<TextMatch> get matches => _matches;

  int _currentMatch = -1;

  /// Which of [matches] is current, or -1 when there are none.
  int get currentMatch => _currentMatch;

  /// The current match, if any.
  TextMatch? get currentTextMatch => _currentMatch < 0 ? null : _matches[_currentMatch];

  /// Finds every occurrence of [query] (ignoring case) and shows the first
  /// one at or below the top of the view.
  @override
  void search(String query) {
    _query = query;
    final needle = query.toLowerCase();
    _matches = needle.isEmpty ? const [] : [for (var i = 0; i < _lines.length; i++) ..._occurrences(i, needle)];
    if (_matches.isEmpty) {
      _currentMatch = -1;
      _updateSearch();
      notifyListeners();
      return;
    }
    final ahead = _matches.indexWhere((m) => m.line >= _topLine);
    _goToMatch(ahead == -1 ? 0 : ahead);
  }

  Iterable<TextMatch> _occurrences(int line, String needle) sync* {
    final text = _lines[line].toLowerCase();
    for (var start = text.indexOf(needle); start != -1; start = text.indexOf(needle, start + needle.length)) {
      yield TextMatch(line, start);
    }
  }

  @override
  void nextMatch() {
    if (_matches.isNotEmpty) _goToMatch((_currentMatch + 1) % _matches.length);
  }

  @override
  void previousMatch() {
    if (_matches.isNotEmpty) _goToMatch((_currentMatch - 1 + _matches.length) % _matches.length);
  }

  void _goToMatch(int index) {
    _currentMatch = index;
    _updateSearch();
    notifyListeners();
    _jumpToLine(_matches[index].line);
  }

  void _updateSearch() =>
      updateSearch(DocumentSearchState(query: _query, matchCount: _matches.length, currentMatch: _currentMatch));

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}
