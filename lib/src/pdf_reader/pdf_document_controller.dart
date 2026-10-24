import 'dart:async';

import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../engines/pdfium/pdf_engine.dart';
import '../engines/pdfium/pdf_types.dart';
import 'pdf_layout.dart';

export 'pdf_layout.dart' show PdfReaderViewMode;

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

/// A search status line: "No searchable text found." for a scanned PDF
/// without a text layer, "No matches" for an ordinary zero-match search.
String pdfSearchStatusLabel({
  required bool hasPattern,
  required bool isSearching,
  required int matchCount,
  required int? currentIndex,
  required bool? hasTextLayer,
}) {
  if (!hasPattern) return '';
  if (isSearching && matchCount == 0) return 'Searching…';
  if (matchCount == 0) return hasTextLayer == false ? 'No searchable text found.' : 'No matches';
  return '${(currentIndex ?? 0) + 1} of $matchCount result(s)';
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
  bool get isSearching => _searching;

  final _matches = <PdfTextMatch>[];
  List<PdfTextMatch> get matches => List.unmodifiable(_matches);
  bool get hasMatches => _matches.isNotEmpty;

  int _current = -1;

  /// Index into [matches], or -1.
  int get currentIndex => _current;
  PdfTextMatch? get currentMatch => _current < 0 ? null : _matches[_current];

  final _byPage = <int, List<int>>{};

  /// [page]'s matches (0-based page) and which of them is current.
  List<(PdfTextMatch, bool)> matchesOn(int page) =>
      [for (final i in _byPage[page] ?? const <int>[]) (_matches[i], i == _current)];

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

/// State for [PdfDocumentView]: the open document (with the password
/// retry), the page on screen, page count, layout, zoom, and search.
///
/// The position is reported through [onPositionChanged] as `{page_number,
/// page_count, view_mode}` on every page change and layout switch; saving
/// it (and debouncing) is the app's business.
class PdfDocumentController extends ChangeNotifier {
  PdfDocumentController({ReadingPosition? initialPosition, this.onPositionChanged}) {
    if (initialPosition != null) restore(initialPosition);
  }

  final ValueChanged<ReadingPosition>? onPositionChanged;

  final searchController = PdfSearchController();

  bool _disposed = false;

  PdfiumDocument? _document;

  /// The open document; null until [open] succeeds.
  PdfiumDocument? get document => _document;

  bool get isReady => _document != null;

  Object? _error;

  /// Why the document couldn't be opened (a [PdfOpenException] or
  /// [PdfEngineException]); null otherwise.
  Object? get error => _error;

  int _initialPage = 1;

  /// The page the viewer opens on.
  int get initialPageNumber => _initialPage;

  int _currentPage = 1;
  int get currentPage => _currentPage;

  int _pageCount = 0;
  int get pageCount => _pageCount;

  PdfReaderViewMode _viewMode = PdfReaderViewMode.continuous;
  PdfReaderViewMode get viewMode => _viewMode;

  bool _viewModeSettled = false;

  /// Whether the layout came from a saved position or the user; an app's
  /// default layout should only apply while this is false.
  bool get viewModeSettled => _viewModeSettled;

  bool? _hasTextLayer;

  /// Null until a zero-match search has looked at every page; then whether
  /// any page had text (false: a scanned PDF).
  bool? get hasTextLayer => _hasTextLayer;

  _PdfViewHandle? _view;

  /// The file open or being opened.
  String? _path;
  Future<void>? _opening;

  /// Opens [path], asking [passwordProvider] for a password (once per try)
  /// while the PDF wants one. Errors end up in [error].
  ///
  /// Opening the file that's already open does nothing, and while it's
  /// still opening returns the same future, so a rebuilt view can't open
  /// (and leak) a second copy. Another file replaces the open one, which is
  /// closed.
  Future<void> open(String path, {PdfPasswordProvider? passwordProvider}) {
    if (path == _path && (_document != null || _opening != null)) return _opening ?? Future.value();
    if (_path != null && path != _path) _discardDocument();
    _path = path;
    late final Future<void> opening;
    opening = _open(path, passwordProvider).whenComplete(() {
      if (identical(_opening, opening)) _opening = null;
    });
    return _opening = opening;
  }

  /// Forgets the open document (and its search) for another file.
  void _discardDocument() {
    unawaited(_document?.close());
    _document = null;
    _error = null;
    _pageCount = 0;
    _hasTextLayer = null;
    searchController._reset(null);
    searchController.notifyListeners();
    notifyListeners();
  }

  Future<void> _open(String path, PdfPasswordProvider? passwordProvider) async {
    _error = null;
    String? password;
    // Superseded by disposal or by another file opened meanwhile.
    bool stale() => _disposed || _path != path;
    while (true) {
      try {
        final document = await PdfiumDocument.openFile(path, password: password);
        if (stale() || _document != null) {
          unawaited(document.close());
          return;
        }
        _document = document;
        _pageCount = document.pageCount;
        _initialPage = _initialPage.clamp(1, document.pageCount < 1 ? 1 : document.pageCount);
        _currentPage = _initialPage;
        break;
      } on PdfOpenException catch (e) {
        if (stale()) return;
        if (e.error == PdfOpenError.password && passwordProvider != null) {
          password = await passwordProvider();
          if (stale()) return;
          if (password != null) continue;
        }
        _error = e;
        break;
      } catch (e) {
        if (stale()) return;
        _error = e;
        break;
      }
    }
    notifyListeners();
  }

  /// Applies a saved position: the page to open on and, when saved, the
  /// layout.
  void restore(ReadingPosition position) {
    if (position[PositionKeys.pageNumber] case final int page when page > 0) _initialPage = page;
    final mode = PdfReaderViewMode.values.asNameMap()[position[PositionKeys.viewMode]];
    if (mode != null && !_viewModeSettled) {
      _viewMode = mode;
      _viewModeSettled = true;
    }
    notifyListeners();
  }

  /// A default layout (e.g. from app settings) for a document with none
  /// saved; ignored once the layout is settled.
  void applyDefaultViewMode(PdfReaderViewMode mode) {
    if (_viewModeSettled) return;
    _viewMode = mode;
    notifyListeners();
  }

  ReadingPosition get position => {
        PositionKeys.pageNumber: _currentPage,
        if (_pageCount > 0) PositionKeys.pageCount: _pageCount,
        PositionKeys.viewMode: _viewMode.name,
      };

  /// The view reports the page being read.
  void onPageChanged(int page) {
    if (page == _currentPage) return;
    _currentPage = page;
    notifyListeners();
    onPositionChanged?.call(position);
  }

  /// Stands in for an open document where no PDF engine runs (unit tests).
  @visibleForTesting
  void debugSetPages({required int pageCount, required int currentPage}) {
    _pageCount = pageCount;
    _currentPage = currentPage;
    notifyListeners();
  }

  Future<void> jumpToPage(int page) async {
    if (_pageCount < 1) return;
    final target = page.clamp(1, _pageCount);
    if (_view case final view?) {
      view.jumpToPage(target - 1);
    } else {
      _initialPage = target;
    }
  }

  void toggleViewMode() {
    _viewModeSettled = true;
    _viewMode = _viewMode == PdfReaderViewMode.continuous ? PdfReaderViewMode.horizontal : PdfReaderViewMode.continuous;
    // The new layout opens on the page being read.
    _initialPage = _currentPage;
    notifyListeners();
    if (_pageCount > 0) onPositionChanged?.call(position);
  }

  static const zoomSteps = [1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0];

  Future<void> zoomIn() async {
    final view = _view;
    if (view == null) return;
    view.setZoom(zoomSteps.firstWhere((z) => z > view.zoom + 0.01, orElse: () => zoomSteps.last));
  }

  Future<void> zoomOut() async {
    final view = _view;
    if (view == null) return;
    view.setZoom(zoomSteps.lastWhere((z) => z < view.zoom - 0.01, orElse: () => zoomSteps.first));
  }

  /// Back to page width (zoom 1).
  Future<void> fitWidth() async => _view?.setZoom(1);

  /// Searches every page for [query] (any case; a phrase may wrap lines),
  /// jumping to the first match as soon as it's found.
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
          if (_disposed || generation != search._generation) return;
          anyText |= hasText;
          if (found.isEmpty) continue;
          search._add(found);
          if (search._current < 0) {
            search._current = 0;
            _view?.showMatch(search._matches.first);
          }
          search.notifyListeners();
        } catch (_) {
          if (_disposed || generation != search._generation) return;
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

  void clearSearch() => search('');

  Future<void> nextMatch() async => _step(1);
  Future<void> previousMatch() async => _step(-1);

  void _step(int delta) {
    final search = searchController;
    if (search._matches.isEmpty) return;
    search._current = (search._current + delta) % search._matches.length;
    search.notifyListeners();
    _view?.showMatch(search._matches[search._current]);
  }

  @override
  void dispose() {
    _disposed = true;
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

/// For [PdfDocumentView] only: connects the view on screen.
extension PdfDocumentControllerView on PdfDocumentController {
  void attachView({
    required double Function() zoom,
    required void Function(double zoom) setZoom,
    required void Function(int page) jumpToPage,
    required void Function(PdfTextMatch match) showMatch,
  }) {
    _view = _ViewCallbacks(zoom, setZoom, jumpToPage, showMatch);
  }

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
  Rect get bounds => rects.isEmpty ? Rect.zero : rects.reduce((a, b) => a.expandToInclude(b));
}
