import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/document_controller.dart';
import '../common/reader_contract.dart';
import '../common/zip_safety_guard.dart';
import '../engines/word/docx_reader.dart';
import '../engines/word/word_model.dart';
import 'word_document_layout.dart';
import 'word_pagination.dart';
import 'word_search_controller.dart';

/// How [WordView] lays a document out.
enum WordViewMode {
  /// Reflowed to the screen, like a web page.
  continuous,

  /// Word's print layout: real pages, each with its headers, footers and
  /// page numbers.
  paged,
}

/// Loads a Word (`.docx`) document for [WordView]: its layout
/// ([viewMode]), zoom, search, the page in view and the scroll position.
///
/// Bytes pass [ZipSafetyGuard] and are parsed off the UI isolate. In print
/// layout, [location] counts pages; reflowed, it's how far through the
/// document the reader is, in percent. The [position] is
/// `{scroll_offset, view_mode, paragraph}`: the offset belongs to that
/// layout, and `paragraph` (the paragraph at the top) lets a thumbnail show
/// the page the reader left off on.
class WordController extends DocumentController {
  /// Reopens in the layout and at the offset saved in [initialPosition],
  /// if any.
  WordController({ReadingPosition? initialPosition, super.onPositionChanged}) {
    if (initialPosition != null) restore(initialPosition);
    _search.addListener(_onSearchChanged);
  }

  /// Applies a saved position: the layout and the offset in it. For an app
  /// that reads the position after creating the controller; call before
  /// the view is shown.
  void restore(ReadingPosition position) {
    _viewMode = WordViewMode.values.asNameMap()[position[PositionKeys.viewMode]] ?? _viewMode;
    if (position[PositionKeys.scrollOffset] case final num offset when offset > 0) {
      initialScrollOffset = offset.toDouble();
    }
  }

  /// Where the document scrolls to once shown. Settable until then.
  double initialScrollOffset = 0;

  /// The view's vertical scrolling.
  @internal
  final scrollController = ScrollController();

  WordDocumentLayout? _layout;

  /// The parsed document laid out for the view; null until loaded.
  @internal
  WordDocumentLayout? get layout => _layout;

  /// The parsed document; null until loaded.
  WordDocument? get document => _layout?.document;

  /// Checks [bytes] with [ZipSafetyGuard], then parses them in a background
  /// isolate.
  @override
  Future<void> loadBytes(Uint8List bytes) async {
    markLoading();
    switch (ZipSafetyGuard.check(bytes)) {
      case ZipSafetyResult.tooLarge:
        markFailed(DocumentLoadError.tooLarge);
      case ZipSafetyResult.corrupted:
        markFailed(DocumentLoadError.corrupted);
      case ZipSafetyResult.safe:
        try {
          final document = await Isolate.run(() => DocxReader.read(bytes));
          if (isDisposed) return;
          final layout = WordDocumentLayout(document);
          _layout = layout;
          _search.setParagraphs([for (final p in layout.paragraphs) p.plainText]);
          _resetLocation();
          markReady();
        } catch (_) {
          markFailed(DocumentLoadError.corrupted);
        }
    }
  }

  // ---- Layout

  WordViewMode _viewMode = WordViewMode.continuous;

  /// Reflowed or print layout.
  WordViewMode get viewMode => _viewMode;

  /// Switches layout; the view keeps the paragraph being read in view.
  set viewMode(WordViewMode mode) {
    if (mode == _viewMode) return;
    _viewMode = mode;
    _pages = null;
    _resetLocation();
    notifyListeners();
  }

  /// Where the reader is until [WordView] has laid the document out: the
  /// first page (of a count not known yet), or the top.
  void _resetLocation() => updateLocation(
    _viewMode == WordViewMode.paged
        ? const DocumentLocation(current: 1, count: 0, unit: DocumentUnit.page)
        : const DocumentLocation(current: 0, count: 100, unit: DocumentUnit.percent),
  );

  /// Switches between [WordViewMode.continuous] and [WordViewMode.paged].
  void toggleViewMode() =>
      viewMode = _viewMode == WordViewMode.continuous ? WordViewMode.paged : WordViewMode.continuous;

  List<WordPage>? _pages;

  /// The number of pages in print layout; null when reflowed, which has no
  /// pages.
  int? get pageCount => _pages?.length;

  /// The pages in print layout, for [WordPageThumbnail].
  @internal
  List<WordPage>? get pages => _pages;

  // ---- Where the reader is

  double _offset = 0;
  int? _topParagraph;

  @override
  ReadingPosition get position => {
    PositionKeys.scrollOffset: _offset,
    PositionKeys.viewMode: _viewMode.name,
    PositionKeys.paragraph: ?_topParagraph,
  };

  /// [WordView] reports its pages (in print layout) and where the reader is.
  @internal
  void reportLayout({List<WordPage>? pages, int? currentPage, required double progress}) {
    _pages = pages;
    updateLocation(
      pages != null
          ? DocumentLocation(current: currentPage ?? 1, count: pages.length, unit: DocumentUnit.page)
          : DocumentLocation(current: (progress * 100).round(), count: 100, unit: DocumentUnit.percent),
    );
  }

  /// [WordView] reports the vertical scroll here, with the paragraph at the
  /// top when it knows it.
  @internal
  void onScrollOffsetChanged(double offset, {int? topParagraph}) {
    _offset = offset;
    if (topParagraph != null) _topParagraph = topParagraph;
    reportPosition();
  }

  int? _pendingPage;

  /// Shows page [number] (from 1) in print layout; reflowed, scrolls
  /// [number] percent of the way through.
  @override
  void goTo(int number) {
    if (_pages case final pages?) {
      _pendingPage = number.clamp(1, pages.length);
      notifyListeners();
    } else if (scrollController.hasClients) {
      final position = scrollController.position;
      position.jumpTo(position.maxScrollExtent * number.clamp(0, 100) / 100);
    }
  }

  /// [WordView] takes the page [goTo] asked for, once.
  @internal
  int? takePendingPage() {
    final page = _pendingPage;
    _pendingPage = null;
    return page;
  }

  // ---- Zoom

  double _zoom = 1;

  /// How large the document is drawn: reflowed, the text reflows at this
  /// scale; in print layout, the pages scale (panning sideways when wider
  /// than the view).
  @override
  double get zoom => _zoom;

  @override
  double get minZoom => 0.5;

  @override
  double get maxZoom => 3;

  @override
  void setZoom(double zoom) {
    zoom = zoom.clamp(minZoom, maxZoom);
    if (zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
  }

  // ---- Search

  final _search = WordSearchController();

  /// The search, for the paragraphs to highlight their matches.
  @internal
  WordSearchController get searchController => _search;

  void _onSearchChanged() => updateSearch(
    DocumentSearchState(query: _search.query, matchCount: _search.matchCount, currentMatch: _search.currentMatchIndex),
  );

  /// Finds every occurrence of [query] (ignoring case) in the body, tables,
  /// headers, footers and notes, and shows the first.
  @override
  void search(String query) => _search.search(query);

  @override
  void clearSearch() => _search.clear();

  @override
  void nextMatch() => _search.next();

  @override
  void previousMatch() => _search.previous();

  @override
  void dispose() {
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    scrollController.dispose();
    super.dispose();
  }
}
