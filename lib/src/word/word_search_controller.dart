import 'package:flutter/foundation.dart';

/// One search hit: characters [start]-[end] of paragraph [paragraph]
/// (a paragraph's index in reading order, see `WordDocumentLayout`).
class WordMatch {
  /// A hit from [start] to [end] in paragraph [paragraph].
  const WordMatch({required this.paragraph, required this.start, required this.end});

  /// The paragraph's number in reading order.
  final int paragraph;

  /// Offset of the first matching character in the paragraph's text.
  final int start;

  /// Offset just past the last matching character (exclusive).
  final int end;
}

/// A highlighted range inside one paragraph.
typedef WordHighlight = ({int start, int end, bool current});

/// Search over a Word document's paragraphs (body, tables, headers,
/// footers and notes), in reading order and ignoring case.
///
/// The text is indexed once ([setParagraphs]); a query is a plain scan of
/// it. Each paragraph asks [highlightsOf] for its own ranges, an O(1)
/// lookup, so a new query doesn't rebuild the whole document.
class WordSearchController extends ChangeNotifier {
  List<String> _folded = const [];

  String _query = '';

  /// The current query; empty when not searching.
  String get query => _query;

  List<WordMatch> _matches = const [];

  /// Every hit for [query], in reading order.
  List<WordMatch> get matches => _matches;

  /// How many hits [query] has.
  int get matchCount => _matches.length;

  int _current = -1;

  /// Index into [matches], or -1 when there are none.
  int get currentMatchIndex => _current;

  /// The selected hit, or null when there are none.
  WordMatch? get currentMatch => _current < 0 ? null : _matches[_current];

  Map<int, List<int>> _byParagraph = const {};

  /// The document's paragraph texts, in reading order. Resets any search.
  void setParagraphs(List<String> texts) {
    _folded = [for (final text in texts) _fold(text)];
    _apply('');
  }

  /// Finds every occurrence of [query], ignoring case, and selects the first.
  void search(String query) => _apply(query);

  /// Ends the search: no query and no hits.
  void clear() => _apply('');

  /// Selects the next hit, wrapping to the first after the last.
  void next() => _step(1);

  /// Selects the previous hit, wrapping to the last before the first.
  void previous() => _step(-1);

  /// The hits in paragraph number [paragraph], marking the selected one.
  List<WordHighlight> highlightsOf(int paragraph) {
    final indices = _byParagraph[paragraph];
    if (indices == null) return const [];
    return [for (final i in indices) (start: _matches[i].start, end: _matches[i].end, current: i == _current)];
  }

  void _apply(String query) {
    _query = query;
    final needle = _fold(query);
    final found = <WordMatch>[];
    if (needle.isNotEmpty) {
      for (var p = 0; p < _folded.length; p++) {
        final text = _folded[p];
        var at = text.indexOf(needle);
        while (at != -1) {
          found.add(WordMatch(paragraph: p, start: at, end: at + needle.length));
          at = text.indexOf(needle, at + needle.length);
        }
      }
    }
    _matches = found;
    final byParagraph = <int, List<int>>{};
    for (var i = 0; i < found.length; i++) {
      (byParagraph[found[i].paragraph] ??= []).add(i);
    }
    _byParagraph = byParagraph;
    _current = found.isEmpty ? -1 : 0;
    notifyListeners();
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    _current = (_current + delta) % _matches.length;
    notifyListeners();
  }

  /// Lower case, one UTF-16 unit at a time, so offsets in the folded text
  /// are offsets in the original (a whole-string `toLowerCase` can change
  /// the length, e.g. `İ` -> `i̇`).
  static String _fold(String text) {
    final lower = text.toLowerCase();
    if (lower.length == text.length) return lower;
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      final folded = String.fromCharCode(unit).toLowerCase();
      out.write(folded.length == 1 ? folded : String.fromCharCode(unit));
    }
    return out.toString();
  }
}
