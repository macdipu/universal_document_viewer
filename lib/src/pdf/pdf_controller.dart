import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/document_controller.dart';
import '../common/reader_contract.dart';
import '../engines/pdfium/pdf_engine.dart';
import '../engines/pdfium/pdf_types.dart';
import 'pdf_layout.dart';

export 'pdf_layout.dart' show PdfViewMode;

/// Whether any of the document's [pageCount] pages carries text. Stops at
/// the first non-blank page. `false` only when every page loaded and was
/// blank (a scanned PDF); `null` when a page wasn't loaded yet
/// ([loadPageText] returns null for it), so the answer is unknown rather
/// than "no text".
Future<bool?> probePdfTextLayer(int pageCount, Future<String?> Function(int pageNumber) loadPageText) async {
  var allLoaded = true;
  for (var page = 1; page <= pageCount; page++) {
    final text = await loadPageText(page);
    if (text == null) {
      allLoaded = false;
    } else if (text.trim().isNotEmpty) {
      return true;
    }
  }
  return allLoaded ? false : null;
}

/// Asked for a password when a PDF is encrypted; null gives up.
typedef PdfPasswordProvider = Future<String?> Function();

/// Text search over a PDF, page by page in the PDF worker; matches arrive
/// as each page is searched.
class PdfSearchController extends ChangeNotifier {
  String? _pattern;

  /// The query, or null when there's no search.
  String? get pattern => _pattern;

  bool _searching = false;

  /// Whether pages are still being searched.
  bool get isSearching => _searching;

  final _matches = <PdfTextMatch>[];

  /// The matches found so far, in page order.
  List<PdfTextMatch> get matches => List.unmodifiable(_matches);

  /// Whether anything was found.
  bool get hasMatches => _matches.isNotEmpty;

  int _current = -1;

  /// Index into [matches], or -1.
  int get currentIndex => _current;

  /// The match on screen, if any.
  PdfTextMatch? get currentMatch => _current < 0 ? null : _matches[_current];

  final _byPage = <int, List<int>>{};

  /// [page]'s matches (0-based page) and which of them is current.
  List<(PdfTextMatch, bool)> matchesOn(int page) => [
    for (final i in _byPage[page] ?? const <int>[]) (_matches[i], i == _current),
  ];

  var _generation = 0;

  void _reset(String? pattern) {
    _generation++;
    _pattern = pattern;
    _matches.clear();
    _byPage.clear();
    _current = -1;
    _searching = false;
  }

  void _add(List<PdfTextMatch> found) {
    for (final match in found) {
      _matches.add(match);
      (_byPage[match.page] ??= []).add(_matches.length - 1);
    }
  }
}

/// Opens a PDF for [PdfView]: the document (asking [passwordProvider]
/// for the password of an encrypted one), the page on screen, the layout
/// ([viewMode]), zoom and search.
///
/// The [position] is `{page_number, page_count, view_mode}`, reported on
/// every page change and layout switch.
class PdfController extends DocumentController {
  /// Reopens on the page and in the layout saved in [initialPosition], if
  /// any.
  PdfController({ReadingPosition? initialPosition, super.onPositionChanged, this.passwordProvider}) {
    if (initialPosition != null) restore(initialPosition);
    searchController.addListener(_onSearchChanged);
  }

  /// Asked for the password of an encrypted PDF, once per attempt, until
  /// it returns null (give up) or the password works. Without one, an
  /// encrypted PDF fails with [DocumentLoadError.passwordRequired].
  final PdfPasswordProvider? passwordProvider;

  /// The search, for the view to draw its matches.
  @internal
  final searchController = PdfSearchController();

  PdfiumDocument? _document;

  /// The open document; null until loaded. For rendering or extracting
  /// text yourself.
  PdfiumDocument? get document => _document;

  Object? _openFailure;

  /// What went wrong opening the document, in the engine's terms (a
  /// [PdfOpenException] or [PdfEngineException]); null unless loading
  /// failed. [error] says the same in [DocumentLoadError] terms.
  Object? get errorDetail => _openFailure;

  /// An encrypted PDF the reader couldn't unlock (no password, a wrong
  /// one, or an encryption PDFium doesn't support) is password protected,
  /// not damaged.
  static DocumentLoadError _loadErrorOf(Object failure) => switch (failure) {
    PdfOpenException(error: PdfOpenError.password || PdfOpenError.security) => DocumentLoadError.passwordRequired,
    _ => DocumentLoadError.corrupted,
  };

  int _initialPage = 1;

  /// The page the viewer opens on.
  int get initialPageNumber => _initialPage;

  int _currentPage = 1;

  /// The page on screen, from 1.
  int get currentPage => _currentPage;

  int _pageCount = 0;

  /// How many pages the document has; 0 until loaded.
  int get pageCount => _pageCount;

  PdfViewMode _viewMode = PdfViewMode.continuous;

  /// Pages one under the other, or side by side.
  PdfViewMode get viewMode => _viewMode;

  bool _viewModeSettled = false;

  /// Whether the layout came from a saved position or the user; an app's
  /// default layout should only apply while this is false.
  bool get viewModeSettled => _viewModeSettled;

  bool? _hasTextLayer;

  /// Null until a zero-match search has looked at every page; then whether
  /// any page had text (false: a scanned PDF).
  bool? get hasTextLayer => _hasTextLayer;

  _PdfViewHandle? _view;

  /// The source open or being opened: a path, or the bytes.
  Object? _source;
  Future<void>? _opening;

  /// Opens the PDF at [path]; PDFium reads the file itself.
  ///
  /// Opening the file that's already open, or opening, does nothing (and
  /// returns the same future). Another file replaces the open one, which
  /// is closed.
  @override
  Future<void> loadFile(String path) => _openSource(path);

  /// Opens a PDF held in memory.
  @override
  Future<void> loadBytes(Uint8List bytes) => _openSource(bytes);

  Future<void> _openSource(Object source) {
    if (source == _source && (_document != null || _opening != null)) return _opening ?? Future.value();
    if (_source != null) _discardDocument();
    _source = source;
    late final Future<void> opening;
    opening = _open(source).whenComplete(() {
      if (identical(_opening, opening)) _opening = null;
    });
    return _opening = opening;
  }

  /// Forgets the open document (and its search) for another one.
  void _discardDocument() {
    unawaited(_document?.close());
    _document = null;
    _openFailure = null;
    _pageCount = 0;
    _hasTextLayer = null;
    searchController._reset(null);
    searchController.notifyListeners();
  }

  Future<void> _open(Object source) async {
    markLoading();
    String? password;
    // Superseded by disposal or by another document opened meanwhile.
    bool stale() => isDisposed || !identical(_source, source);
    while (true) {
      try {
        final document = switch (source) {
          final String path => await PdfiumDocument.openFile(path, password: password),
          final Uint8List bytes => await PdfiumDocument.openBytes(bytes, password: password),
          _ => throw ArgumentError.value(source),
        };
        if (stale() || _document != null) {
          unawaited(document.close());
          return;
        }
        _document = document;
        _pageCount = document.pageCount;
        _initialPage = _initialPage.clamp(1, document.pageCount < 1 ? 1 : document.pageCount);
        _currentPage = _initialPage;
        _updateLocation();
        markReady();
        return;
      } on PdfOpenException catch (e) {
        if (stale()) return;
        if (e.error == PdfOpenError.password && passwordProvider != null) {
          password = await passwordProvider!();
          if (stale()) return;
          if (password != null) continue;
        }
        _fail(e);
        return;
      } catch (e) {
        if (stale()) return;
        _fail(e);
        return;
      }
    }
  }

  void _fail(Object failure) {
    _openFailure = failure;
    markFailed(_loadErrorOf(failure));
  }

  void _updateLocation() =>
      updateLocation(DocumentLocation(current: _currentPage, count: _pageCount, unit: DocumentUnit.page));

  /// Applies a saved position: the page to open on and, when saved, the
  /// layout.
  void restore(ReadingPosition position) {
    if (position[PositionKeys.pageNumber] case final int page when page > 0) _initialPage = page;
    final mode = PdfViewMode.values.asNameMap()[position[PositionKeys.viewMode]];
    if (mode != null && !_viewModeSettled) {
      _viewMode = mode;
      _viewModeSettled = true;
    }
    notifyListeners();
  }

  /// A default layout (e.g. from app settings) for a document with none
  /// saved; ignored once the layout is settled.
  void applyDefaultViewMode(PdfViewMode mode) {
    if (_viewModeSettled) return;
    _viewMode = mode;
    notifyListeners();
  }

  @override
  ReadingPosition get position => {
    PositionKeys.pageNumber: _currentPage,
    if (_pageCount > 0) PositionKeys.pageCount: _pageCount,
    PositionKeys.viewMode: _viewMode.name,
  };

  /// [PdfView] reports the page being read.
  @internal
  void onPageChanged(int page) {
    if (page == _currentPage) return;
    _currentPage = page;
    _updateLocation();
    notifyListeners();
    reportPosition();
  }

  /// Stands in for an open document where no PDF engine runs (unit tests).
  @visibleForTesting
  void debugSetPages({required int pageCount, required int currentPage}) {
    _pageCount = pageCount;
    _currentPage = currentPage;
    _updateLocation();
    notifyListeners();
  }

  /// Shows page [number] (from 1).
  @override
  void goTo(int number) => unawaited(jumpToPage(number));

  /// Shows [page] (from 1), clamped to the document.
  Future<void> jumpToPage(int page) async {
    if (_pageCount < 1) return;
    final target = page.clamp(1, _pageCount);
    if (_view case final view?) {
      view.jumpToPage(target - 1);
    } else {
      _initialPage = target;
    }
  }

  /// Switches between pages one under the other and side by side.
  void toggleViewMode() {
    _viewModeSettled = true;
    _viewMode = _viewMode == PdfViewMode.continuous ? PdfViewMode.horizontal : PdfViewMode.continuous;
    // The new layout opens on the page being read.
    _initialPage = _currentPage;
    notifyListeners();
    if (_pageCount > 0) reportPosition();
  }

  // ---- Zoom

  /// The zoom levels [zoomIn] and [zoomOut] step through.
  static const zoomSteps = [1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0];

  /// The zoom on screen: 1 is page width. Pinching and double-tapping
  /// change it too.
  @override
  double get zoom => _view?.zoom ?? 1;

  @override
  double get minZoom => zoomSteps.first;

  @override
  double get maxZoom => zoomSteps.last;

  @override
  void setZoom(double zoom) => _view?.setZoom(zoom.clamp(minZoom, maxZoom));

  /// Zooms in to the next of [zoomSteps].
  @override
  void zoomIn() => setZoom(zoomSteps.firstWhere((z) => z > zoom + 0.01, orElse: () => zoomSteps.last));

  /// Zooms out to the previous of [zoomSteps].
  @override
  void zoomOut() => setZoom(zoomSteps.lastWhere((z) => z < zoom - 0.01, orElse: () => zoomSteps.first));

  /// Back to page width (zoom 1).
  void fitWidth() => setZoom(1);

  double _reportedZoom = 1;

  /// [PdfView] reports zoom changes (from pinches too) here.
  @internal
  void onZoomChanged() {
    final zoom = this.zoom;
    if ((zoom - _reportedZoom).abs() < 0.001) return;
    _reportedZoom = zoom;
    notifyListeners();
  }

  // ---- Search

  void _onSearchChanged() {
    final search = searchController;
    updateSearch(
      DocumentSearchState(
        query: search.pattern ?? '',
        matchCount: search._matches.length,
        currentMatch: search._current,
        isSearching: search._searching,
        hasSearchableText: _hasTextLayer != false,
      ),
    );
  }

  /// Searches every page for [query] (ignoring case; a phrase may wrap
  /// lines), jumping to the first match as soon as it's found. Pages are
  /// searched in the background: [searchState] reports the matches as they
  /// arrive.
  @override
  void search(String query) {
    final search = searchController;
    final document = _document;
    final trimmed = query.trim();
    search._reset(trimmed.isEmpty ? null : trimmed);
    if (trimmed.isEmpty || document == null) {
      search.notifyListeners();
      return;
    }
    final generation = search._generation;
    search._searching = true;
    search.notifyListeners();
    () async {
      var anyText = false;
      for (var page = 0; page < document.pageCount; page++) {
        try {
          final (hasText, found) = await document.search(page, trimmed);
          if (isDisposed || generation != search._generation) return;
          anyText |= hasText;
          if (found.isEmpty) continue;
          search._add(found);
          if (search._current < 0) {
            search._current = 0;
            _view?.showMatch(search._matches.first);
          }
          search.notifyListeners();
        } catch (_) {
          if (isDisposed || generation != search._generation) return;
        }
      }
      search._searching = false;
      if (search._matches.isEmpty && _hasTextLayer == null) {
        _hasTextLayer = anyText;
        notifyListeners();
      }
      search.notifyListeners();
    }();
  }

  @override
  void nextMatch() => _step(1);

  @override
  void previousMatch() => _step(-1);

  void _step(int delta) {
    final search = searchController;
    if (search._matches.isEmpty) return;
    search._current = (search._current + delta) % search._matches.length;
    search.notifyListeners();
    _view?.showMatch(search._matches[search._current]);
  }

  @override
  void dispose() {
    searchController.removeListener(_onSearchChanged);
    searchController.dispose();
    unawaited(_document?.close());
    super.dispose();
  }
}

/// What the controller needs from the view on screen.
abstract interface class _PdfViewHandle {
  double get zoom;
  void setZoom(double zoom);
  void jumpToPage(int page);
  void showMatch(PdfTextMatch match);
}

/// For [PdfView] only: connects the view on screen.
@internal
extension PdfControllerView on PdfController {
  /// Connects the view on screen.
  void attachView({
    required double Function() zoom,
    required void Function(double zoom) setZoom,
    required void Function(int page) jumpToPage,
    required void Function(PdfTextMatch match) showMatch,
  }) {
    _view = _ViewCallbacks(zoom, setZoom, jumpToPage, showMatch);
  }

  /// Disconnects the view.
  void detachView() => _view = null;
}

class _ViewCallbacks implements _PdfViewHandle {
  _ViewCallbacks(this._zoom, this._setZoom, this._jumpToPage, this._showMatch);

  final double Function() _zoom;
  final void Function(double) _setZoom;
  final void Function(int) _jumpToPage;
  final void Function(PdfTextMatch) _showMatch;

  @override
  double get zoom => _zoom();

  @override
  void setZoom(double zoom) => _setZoom(zoom);

  @override
  void jumpToPage(int page) => _jumpToPage(page);

  @override
  void showMatch(PdfTextMatch match) => _showMatch(match);
}

/// Rect helpers for page-space search hits.
extension PdfMatchRects on PdfTextMatch {
  /// The rectangle around all of the match's line rectangles.
  Rect get bounds => rects.isEmpty ? Rect.zero : rects.reduce((a, b) => a.expandToInclude(b));
}
