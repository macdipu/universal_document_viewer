
import 'package:flutter/foundation.dart';

import 'document_controller.dart';
import 'reader_contract.dart';
import 'text_decoding.dart';

/// One occurrence of a search in a text document: on line [line]
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

/// What the text formats (plain text, Markdown) share: decoding a file into
/// lines, zoom, and case-insensitive search over those lines.
///
/// Text is decoded as UTF-8, or after a UTF-16 byte order mark, falling back
/// to Latin-1. A subclass says where the reader is ([topLine]), how to show a
/// line ([revealLine]) and what the saved [position] holds.
abstract class TextLinesController extends DocumentController {
  /// Reopens at the scroll offset saved in [initialPosition], if any.
  TextLinesController({ReadingPosition? initialPosition, super.onPositionChanged})
      : initialScrollOffset = switch (initialPosition?[PositionKeys.scrollOffset]) {
          final num offset when offset > 0 => offset.toDouble(),
          _ => 0,
        };

  /// Above this size a file is refused rather than read into memory in one
  /// pass.
  static const int maxBytes = 20 * 1024 * 1024;

  @override
  int get maxFileBytes => maxBytes;

  /// Where the view scrolls to once laid out (from the saved position).
  /// Settable until then, for an app that reads the saved position after
  /// creating the controller.
  double initialScrollOffset;

  List<String> _lines = const [];

  /// The document's lines.
  List<String> get lines => _lines;

  /// Checks [bytes] look like text, then decodes them into lines.
  @override
  Future<void> loadBytes(Uint8List bytes) async {
    markLoading();
    if (bytes.length > maxBytes) {
      markFailed(DocumentLoadError.tooLarge);
    } else if (looksLikeBinary(bytes)) {
      markFailed(DocumentLoadError.corrupted);
    } else {
      _lines = decodeTextBytes(bytes).split('\n');
      updateLineLocation(0);
      markReady();
    }
  }

  /// Whether [bytes] look like a binary file rather than text; see
  /// [looksLikeBinary], which this forwards to.
  static bool looksBinary(Uint8List bytes) => looksLikeBinary(bytes);

  // ---- Where the reader is

  /// The line (from 0) at the top of the view; a search starts from here.
  @protected
  int get topLine;

  /// The reader is now at line [topLine] (from 0).
  @protected
  void updateLineLocation(int topLine) =>
      updateLocation(DocumentLocation(current: topLine + 1, count: _lines.length, unit: DocumentUnit.line));

  /// Brings line [lineIndex] (from 0) into view, for a search match.
  @protected
  void revealLine(int lineIndex);

  // ---- Zoom

  double _zoom = 1;

  /// Scales the view's font size: the text reflows at the new size.
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
    final ahead = _matches.indexWhere((m) => m.line >= topLine);
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
    revealLine(_matches[index].line);
  }

  void _updateSearch() =>
      updateSearch(DocumentSearchState(query: _query, matchCount: _matches.length, currentMatch: _currentMatch));
}
