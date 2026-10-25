import 'dart:io';

import 'package:flutter/foundation.dart';

import 'reader_contract.dart';
import 'zip_safety_guard.dart';

/// Where a [DocumentController] is in its document's life.
enum DocumentStatus {
  /// Nothing loaded yet.
  idle,

  /// [DocumentController.loadFile] or [DocumentController.loadBytes] is
  /// running.
  loading,

  /// The document is loaded and can be shown.
  ready,

  /// The document couldn't be loaded; see [DocumentController.error].
  failed,
}

/// What [DocumentLocation.current] and [DocumentLocation.count] count.
enum DocumentUnit {
  /// PDF pages, and Word pages in print layout.
  page,

  /// PowerPoint slides.
  slide,

  /// Spreadsheet rows.
  row,

  /// Lines of plain text.
  line,

  /// How far through the document, from 0 to 100, where a document has no
  /// pages (Word's continuous layout).
  percent,
}

/// Where the reader is in a document: "page 3 of 12", "row 40 of 900".
@immutable
class DocumentLocation {
  /// A location of [current] out of [count] [unit]s.
  const DocumentLocation({required this.current, required this.count, required this.unit});

  /// Before a document is loaded.
  static const none = DocumentLocation(current: 0, count: 0, unit: DocumentUnit.page);

  /// The page, slide, row or line in view, from 1; or the percentage, from
  /// 0, for [DocumentUnit.percent].
  final int current;

  /// How many there are (100 for [DocumentUnit.percent]).
  final int count;

  /// What [current] and [count] count.
  final DocumentUnit unit;

  @override
  bool operator ==(Object other) =>
      other is DocumentLocation && other.current == current && other.count == count && other.unit == unit;

  @override
  int get hashCode => Object.hash(current, count, unit);

  @override
  String toString() => 'DocumentLocation($current of $count ${unit.name})';
}

/// A search in a document: the query, how many times it occurs and which
/// occurrence is current.
@immutable
class DocumentSearchState {
  /// A search for [query] with [matchCount] occurrences, [currentMatch]
  /// being the one shown.
  const DocumentSearchState({
    required this.query,
    required this.matchCount,
    required this.currentMatch,
    this.isSearching = false,
    this.hasSearchableText = true,
  });

  /// No search.
  static const none = DocumentSearchState(query: '', matchCount: 0, currentMatch: -1);

  /// What is being searched for; empty when there's no search.
  final String query;

  /// How many times [query] occurs (so far, while [isSearching]).
  final int matchCount;

  /// Which occurrence is current, from 0; -1 when there are none.
  final int currentMatch;

  /// Whether the search is still running. PDF searches page by page in the
  /// background; the other formats finish at once.
  final bool isSearching;

  /// False when the whole document was searched and had no text to search
  /// at all: a scanned PDF. A reason to say so instead of "No matches".
  final bool hasSearchableText;

  /// Whether there's a query.
  bool get isActive => query.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is DocumentSearchState &&
      other.query == query &&
      other.matchCount == matchCount &&
      other.currentMatch == currentMatch &&
      other.isSearching == isSearching &&
      other.hasSearchableText == hasSearchableText;

  @override
  int get hashCode => Object.hash(query, matchCount, currentMatch, isSearching, hasSearchableText);

  @override
  String toString() => 'DocumentSearchState("$query", ${currentMatch + 1} of $matchCount)';
}

/// What every format's controller does, so an app can build one toolbar,
/// search bar and position display for all of them.
///
/// A controller loads one document ([loadFile] or [loadBytes]), reports
/// where the reader is ([location], [position]), zooms ([zoom]) and
/// searches ([search], [searchState]). Show it with the format's view.
/// Each format adds its own extras on top: PDF's page layout, Word's print
/// layout, a spreadsheet's sheets, and so on.
///
/// Controllers are plain [ChangeNotifier]s with no storage of their own:
/// save [position] wherever the app keeps such things and pass it back as
/// `initialPosition` to reopen there. Dispose a controller you create.
abstract class DocumentController extends ChangeNotifier {
  /// Reports [position] to [onPositionChanged] as the reader moves.
  DocumentController({this.onPositionChanged});

  /// Called as the reader moves through the document, with the [position]
  /// to save. Debouncing and storage are up to the app.
  final ValueChanged<ReadingPosition>? onPositionChanged;

  // ---- Loading

  DocumentStatus _status = DocumentStatus.idle;

  /// Whether the document is loading, ready or failed.
  DocumentStatus get status => _status;

  /// True once loading has finished, successfully or not.
  bool get isLoaded => _status == DocumentStatus.ready || _status == DocumentStatus.failed;

  DocumentLoadError? _error;

  /// Why the document couldn't be loaded; null unless [status] is
  /// [DocumentStatus.failed].
  DocumentLoadError? get error => _error;

  bool _disposed = false;

  /// Whether [dispose] has been called. A load that finishes afterwards
  /// discards its result.
  @protected
  bool get isDisposed => _disposed;

  /// The largest file [loadFile] reads. Bigger files fail with
  /// [DocumentLoadError.tooLarge] before anything is read.
  @protected
  int get maxFileBytes => ZipSafetyGuard.maxFileBytes;

  /// Loads the document at [path].
  ///
  /// Checks its size against the format's limit first, so a huge file is
  /// refused before it is read into memory. A file that can't be read
  /// fails with [DocumentLoadError.corrupted].
  Future<void> loadFile(String path) async {
    markLoading();
    final Uint8List bytes;
    try {
      final file = File(path);
      if (await file.length() > maxFileBytes) {
        markFailed(DocumentLoadError.tooLarge);
        return;
      }
      bytes = await file.readAsBytes();
    } catch (_) {
      markFailed(DocumentLoadError.corrupted);
      return;
    }
    if (_disposed) return;
    await loadBytes(bytes);
  }

  /// Loads the document from [bytes].
  Future<void> loadBytes(Uint8List bytes);

  /// For a format's controller: loading has started.
  @protected
  void markLoading() {
    if (_disposed) return;
    _status = DocumentStatus.loading;
    _error = null;
    notifyListeners();
  }

  /// For a format's controller: the document is loaded.
  @protected
  void markReady() {
    if (_disposed) return;
    _status = DocumentStatus.ready;
    _error = null;
    notifyListeners();
  }

  /// For a format's controller, or an app whose own read of the file
  /// failed: the document can't be shown, because of [error].
  void markFailed(DocumentLoadError error) {
    if (_disposed) return;
    _status = DocumentStatus.failed;
    _error = error;
    notifyListeners();
  }

  // ---- Where the reader is

  final _location = ValueNotifier(DocumentLocation.none);

  /// Where the reader is, updated as they move: listen to it for a "page 3
  /// of 12" display without rebuilding on every other change.
  ValueListenable<DocumentLocation> get location => _location;

  /// For a format's controller: the reader is now at [location].
  @protected
  void updateLocation(DocumentLocation location) {
    if (!_disposed) _location.value = location;
  }

  /// Moves to page, slide, row or line [number] (from 1) of
  /// [location]'s unit, or to [number] percent through for
  /// [DocumentUnit.percent]. Out-of-range numbers are clamped.
  void goTo(int number);

  /// The place to save, as JSON-safe values: pass it back as
  /// `initialPosition` to reopen there.
  ReadingPosition get position;

  /// Reports [position] to [onPositionChanged].
  @protected
  void reportPosition() {
    if (!_disposed) onPositionChanged?.call(position);
  }

  // ---- Zoom

  /// The zoom factor; 1 is the format's natural size.
  double get zoom;

  /// The smallest [zoom].
  double get minZoom;

  /// The largest [zoom].
  double get maxZoom;

  /// How much [zoomIn] and [zoomOut] change [zoom] by.
  double get zoomStep => 0.25;

  /// Whether [zoomIn] would zoom in.
  bool get canZoomIn => zoom < maxZoom - 1e-9;

  /// Whether [zoomOut] would zoom out.
  bool get canZoomOut => zoom > minZoom + 1e-9;

  /// Sets [zoom], clamped to [minZoom]..[maxZoom].
  void setZoom(double zoom);

  /// Zooms in one step.
  void zoomIn() => setZoom(zoom + zoomStep);

  /// Zooms out one step.
  void zoomOut() => setZoom(zoom - zoomStep);

  // ---- Search

  final _searchState = ValueNotifier(DocumentSearchState.none);

  /// The current search, updated as it runs and as the reader steps
  /// through its matches.
  ValueListenable<DocumentSearchState> get searchState => _searchState;

  /// For a format's controller: the search is now [state].
  @protected
  void updateSearch(DocumentSearchState state) {
    if (!_disposed) _searchState.value = state;
  }

  /// Searches for [query] (ignoring case) and shows the first match from
  /// where the reader is. An empty query ends the search.
  void search(String query);

  /// Shows the next match, wrapping round after the last.
  void nextMatch();

  /// Shows the previous match, wrapping round before the first.
  void previousMatch();

  /// Ends the search and removes its highlights.
  void clearSearch() => search('');

  @override
  void dispose() {
    _disposed = true;
    _location.dispose();
    _searchState.dispose();
    super.dispose();
  }
}
