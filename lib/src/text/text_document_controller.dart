import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../common/text_decoding.dart';

/// State for [TextDocumentView]: a plain-text file's lines, search across
/// them, and the scroll position.
///
/// The position is reported through [onPositionChanged] as
/// `{scroll_offset, line}` on every scroll (`line`, the top visible line,
/// once the view has measured its lines); saving it (and debouncing) is
/// the app's business.
class TextDocumentController extends ChangeNotifier {
  TextDocumentController({ReadingPosition? initialPosition, this.onPositionChanged})
    : initialScrollOffset = switch (initialPosition?[PositionKeys.scrollOffset]) {
        final num offset when offset > 0 => offset.toDouble(),
        _ => 0,
      };

  /// Above this size a file is refused rather than read into memory in one
  /// pass. A first-pass, adjustable ceiling.
  static const int maxBytes = 20 * 1024 * 1024;

  /// Fallback line height for jump-to-match before the view has measured
  /// real lines.
  static const double _approxLineHeight = 20;

  /// Where the view scrolls to once laid out (from the saved position).
  /// Settable until then, for an app that reads the saved position after
  /// creating the controller.
  double initialScrollOffset;

  final ValueChanged<ReadingPosition>? onPositionChanged;

  final scrollController = ScrollController();

  /// Scroll offset of a line's top, measured by the view against the real
  /// font, width and wrap. Null until the view lays out.
  double Function(int lineIndex)? lineOffsetResolver;

  /// The line at a scroll offset: the inverse of [lineOffsetResolver], set
  /// by the view alongside it.
  int Function(double offset)? lineAtOffsetResolver;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  DocumentLoadError? _error;
  DocumentLoadError? get error => _error;

  List<String> _lines = const [];
  List<String> get lines => _lines;

  /// Checks [bytes] look like text, then decodes them (UTF-8, else
  /// Latin-1; UTF-16 after its byte order mark) into lines. A caller reading from a file should refuse files
  /// over [maxBytes] before reading them.
  void load(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      _error = DocumentLoadError.tooLarge;
    } else if (looksBinary(bytes)) {
      _error = DocumentLoadError.corrupted;
    } else {
      _lines = decodeTextBytes(bytes).split('\n');
    }
    _loaded = true;
    notifyListeners();
  }

  /// A cheap heuristic, not a real content-type sniffer: a NUL byte, or a
  /// high proportion of non-whitespace control bytes in a leading sample,
  /// is treated as "not text" (e.g. a binary file renamed `.txt`). False
  /// positives/negatives are possible on edge-case files. UTF-16 text with a
  /// byte order mark is text, whatever its NUL bytes.
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

  /// The view reports every scroll here.
  void onScrolled(double offset) => onPositionChanged?.call({
    PositionKeys.scrollOffset: offset,
    if (lineAtOffsetResolver?.call(offset) case final line?) PositionKeys.line: line,
  });

  String _query = '';
  String get searchQuery => _query;

  List<int> _matches = const [];

  /// Indices of the lines containing [searchQuery].
  List<int> get matches => _matches;

  int _currentMatch = -1;

  /// Position within [matches], or -1 when there are none.
  int get currentMatch => _currentMatch;

  /// Finds the lines containing [query] (any case) and jumps to the first.
  void search(String query) {
    _query = query;
    final lower = query.toLowerCase();
    _matches = query.isEmpty
        ? const []
        : [
            for (var i = 0; i < _lines.length; i++)
              if (_lines[i].toLowerCase().contains(lower)) i,
          ];
    _currentMatch = _matches.isEmpty ? -1 : 0;
    notifyListeners();
    if (_matches.isNotEmpty) _jumpToLine(_matches.first);
  }

  void clearSearch() => search('');

  void nextMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch + 1) % _matches.length;
    notifyListeners();
    _jumpToLine(_matches[_currentMatch]);
  }

  void previousMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch - 1 + _matches.length) % _matches.length;
    notifyListeners();
    _jumpToLine(_matches[_currentMatch]);
  }

  void _jumpToLine(int lineIndex) {
    if (!scrollController.hasClients) return;
    final offset = lineOffsetResolver?.call(lineIndex) ?? lineIndex * _approxLineHeight;
    final target = offset.clamp(0.0, scrollController.position.maxScrollExtent);
    scrollController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}
