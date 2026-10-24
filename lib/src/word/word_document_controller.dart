import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../common/zip_safety_guard.dart';
import '../engines/word/docx_reader.dart';
import '../engines/word/word_model.dart';
import 'word_document_layout.dart';
import 'word_search_controller.dart';

/// How [WordDocumentView] lays the document out.
enum WordViewMode {
  /// Reflowed to the screen.
  continuous,

  /// Word's print layout: real pages.
  paged,
}

/// State for [WordDocumentView]: a `.docx` checked by [ZipSafetyGuard] and
/// parsed off the UI isolate, search within it, the layout ([viewMode]) and
/// the scroll position.
///
/// The position is reported through [onPositionChanged] as
/// `{scroll_offset, view_mode, paragraph}` (the offset belongs to that
/// layout; `paragraph`, the number of the paragraph at the top, is there
/// once the view has found it); saving it (and debouncing) is the app's
/// business.
class WordDocumentController extends ChangeNotifier {
  WordDocumentController({ReadingPosition? initialPosition, this.onPositionChanged}) {
    if (initialPosition != null) restore(initialPosition);
  }

  /// Applies a saved position: the layout and the offset in it. For an
  /// app that reads the position after creating the controller; call
  /// before the view is shown.
  void restore(ReadingPosition position) {
    _viewMode = WordViewMode.values.asNameMap()[position[PositionKeys.viewMode]] ?? _viewMode;
    if (position[PositionKeys.scrollOffset] case final num offset when offset > 0) {
      initialScrollOffset = offset.toDouble();
    }
  }

  /// Where the document scrolls to once shown. Settable until then, for an
  /// app that reads the saved position after creating the controller.
  double initialScrollOffset = 0;

  WordViewMode _viewMode = WordViewMode.continuous;
  WordViewMode get viewMode => _viewMode;

  /// Switches layout; the view keeps the paragraph being read in view.
  set viewMode(WordViewMode mode) {
    if (mode == _viewMode) return;
    _viewMode = mode;
    notifyListeners();
  }

  void toggleViewMode() =>
      viewMode = _viewMode == WordViewMode.continuous ? WordViewMode.paged : WordViewMode.continuous;

  final ValueChanged<ReadingPosition>? onPositionChanged;

  final searchController = WordSearchController();
  final scrollController = ScrollController();

  bool _disposed = false;

  bool _loaded = false;

  /// True once [load] finished, successfully or not.
  bool get isLoaded => _loaded;

  DocumentLoadError? _error;
  DocumentLoadError? get error => _error;

  WordDocumentLayout? _layout;

  /// The parsed document laid out for display; null until [load] succeeds.
  WordDocumentLayout? get layout => _layout;
  WordDocument? get document => _layout?.document;

  /// Checks [bytes] with [ZipSafetyGuard], then parses them in a background
  /// isolate.
  Future<void> load(Uint8List bytes) async {
    switch (ZipSafetyGuard.check(bytes)) {
      case ZipSafetyResult.tooLarge:
        _error = DocumentLoadError.tooLarge;
      case ZipSafetyResult.corrupted:
        _error = DocumentLoadError.corrupted;
      case ZipSafetyResult.safe:
        try {
          final document = await Isolate.run(() => DocxReader.read(bytes));
          if (_disposed) return;
          final layout = WordDocumentLayout(document);
          _layout = layout;
          searchController.setParagraphs([for (final p in layout.paragraphs) p.plainText]);
        } catch (_) {
          _error = DocumentLoadError.corrupted;
        }
    }
    if (_disposed) return;
    _loaded = true;
    notifyListeners();
  }

  /// For a caller whose own read failed (e.g. the file vanished). A no-op
  /// once disposed: the read can fail because the reader was closed.
  void rejectAsCorrupted() {
    if (_disposed) return;
    _error = DocumentLoadError.corrupted;
    _loaded = true;
    notifyListeners();
  }

  /// The view reports the document's vertical scroll here, with the
  /// number of the paragraph at the top when it knows it.
  void onScrollOffsetChanged(double offset, {int? topParagraph}) => onPositionChanged?.call({
    PositionKeys.scrollOffset: offset,
    PositionKeys.viewMode: _viewMode.name,
    PositionKeys.paragraph: ?topParagraph,
  });

  void search(String query) => searchController.search(query);
  void clearSearch() => searchController.clear();
  void nextMatch() => searchController.next();
  void previousMatch() => searchController.previous();

  @override
  void dispose() {
    _disposed = true;
    searchController.dispose();
    scrollController.dispose();
    super.dispose();
  }
}
