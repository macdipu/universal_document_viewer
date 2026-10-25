import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../common/zip_safety_guard.dart';
import '../engines/word/docx_reader.dart';
import '../engines/word/word_model.dart';
import 'word_document_layout.dart';
import 'word_pagination.dart';
import 'word_search_controller.dart';

/// How [WordView] lays the document out.
enum WordViewMode {
  /// Reflowed to the screen.
  continuous,

  /// Word's print layout: real pages.
  paged,
}

/// State for [WordView]: a `.docx` checked by [ZipSafetyGuard] and
/// parsed off the UI isolate, search within it, the layout ([viewMode]),
/// [zoom], the page in view and the scroll position.
///
/// The position is reported through [onPositionChanged] as
/// `{scroll_offset, view_mode, paragraph}` (the offset belongs to that
/// layout; `paragraph`, the number of the paragraph at the top, is there
/// once the view has found it); saving it (and debouncing) is the app's
/// business.
class WordController extends ChangeNotifier {
  WordController({ReadingPosition? initialPosition, this.onPositionChanged}) {
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

  static const double minZoom = 0.5;
  static const double maxZoom = 3.0;
  static const double zoomStep = 0.25;

  double _zoom = 1;

  /// How large the document is drawn: the text reflows at this scale in
  /// [WordViewMode.continuous]; the pages scale (panning sideways when
  /// wider than the view) in [WordViewMode.paged].
  double get zoom => _zoom;
  bool get canZoomIn => _zoom < maxZoom;
  bool get canZoomOut => _zoom > minZoom;

  void zoomIn() => _setZoom(_zoom + zoomStep);
  void zoomOut() => _setZoom(_zoom - zoomStep);

  void _setZoom(double value) {
    final zoom = value.clamp(minZoom, maxZoom);
    if (zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
  }

  final _pageCount = ValueNotifier<int?>(null);
  final _currentPage = ValueNotifier<int>(1);
  final _progress = ValueNotifier<double>(0);

  /// The number of pages in [WordViewMode.paged]; null in
  /// [WordViewMode.continuous], which has no pages.
  ValueListenable<int?> get pageCount => _pageCount;

  /// The (1-based) page in view, in [WordViewMode.paged].
  ValueListenable<int> get currentPage => _currentPage;

  /// How far through the document the view is scrolled, 0 to 1.
  ValueListenable<double> get progress => _progress;

  int? _pendingPage;

  /// Scrolls to [page] (1-based) in [WordViewMode.paged]; ignored otherwise.
  void goToPage(int page) {
    final count = _pageCount.value;
    if (count == null) return;
    _pendingPage = page.clamp(1, count);
    notifyListeners();
  }

  /// For [WordView]: the page asked for by [goToPage], once.
  int? takePendingPage() {
    final page = _pendingPage;
    _pendingPage = null;
    return page;
  }

  List<WordPage>? _pages;

  /// The pages in [WordViewMode.paged], for [WordPageThumbnail]; null in
  /// [WordViewMode.continuous]. [pageCount] changes when they do.
  List<WordPage>? get pages => _pages;

  /// For [WordView]: the pages, and where the reader is.
  void reportLayout({List<WordPage>? pages, int? currentPage, double? progress}) {
    _pages = pages;
    _pageCount.value = pages?.length;
    if (currentPage != null) _currentPage.value = currentPage;
    if (progress != null) _progress.value = progress;
  }

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
    _pageCount.dispose();
    _currentPage.dispose();
    _progress.dispose();
    super.dispose();
  }
}
