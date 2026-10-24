import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../common/text_decoding.dart';
import '../common/zip_safety_guard.dart';
import '../engines/sheets/csv_reader.dart';
import '../engines/sheets/workbook.dart';
import '../engines/sheets/xlsx_reader.dart';
import 'cell_match.dart';
import 'sheet_geometry.dart';

/// State for [SheetGrid]: a workbook's sheets (or a CSV's single sheet),
/// the sheet on screen, search within it, zoom and scrolling.
///
/// Position is reported through [onPositionChanged] on every scroll and
/// sheet switch as `{sheet_index, row, column, vertical_offset,
/// horizontal_offset}`, offsets at 1x zoom; saving it (and debouncing) is
/// the app's business.
///
/// Rows and columns take the sizes stored in the file, and hidden ones stay
/// hidden ([geometry]). [goTo] jumps to a cell or sheet; [freezeTopRow]
/// keeps the header row on screen in a sheet whose file froze none.
/// `freeze_top_row` is in the position when it's on.
class SpreadsheetController extends ChangeNotifier {
  SpreadsheetController({ReadingPosition? initialPosition, this.onPositionChanged}) {
    final position = initialPosition ?? const {};
    if (position[PositionKeys.sheetIndex] case final int index when index >= 0) _initialSheetIndex = index;
    if (position[PositionKeys.verticalOffset] case final num v when v > 0) {
      initialVerticalOffset = _lastVerticalOffset = v.toDouble();
    }
    if (position[PositionKeys.horizontalOffset] case final num h when h > 0) {
      initialHorizontalOffset = _lastHorizontalOffset = h.toDouble();
    }
    _freezeTopRow = position[PositionKeys.freezeTopRow] == true;
  }

  /// A default-width column and default-height row; see [SheetGeometry].
  static const double cellWidth = SheetGeometry.defaultColumnWidth;
  static const double cellHeight = SheetGeometry.defaultRowHeight;
  static const double rowHeaderWidth = 48;

  static const double minZoom = 0.75;
  static const double maxZoom = 2.0;
  static const double zoomStep = 0.25;

  /// Above this size a CSV is refused rather than parsed in one pass. A
  /// first-pass, adjustable ceiling.
  static const int maxCsvBytes = 20 * 1024 * 1024;

  final ValueChanged<ReadingPosition>? onPositionChanged;

  int _initialSheetIndex = 0;

  /// Where the grid scrolls to once laid out, at 1x zoom.
  double initialVerticalOffset = 0;
  double initialHorizontalOffset = 0;

  final verticalController = ScrollController();
  final horizontalController = ScrollController();

  /// Last-known offsets, refreshed whenever the scroll views are attached.
  /// [position] uses these: once a route's scroll views detach, reading the
  /// controllers would give 0.
  double _lastVerticalOffset = 0;
  double _lastHorizontalOffset = 0;

  bool _disposed = false;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  DocumentLoadError? _error;
  DocumentLoadError? get error => _error;

  List<Worksheet> _sheets = const [];

  /// Visible sheets' names, in workbook order. A CSV has one.
  List<String> get sheetNames => [for (final sheet in _sheets) sheet.name];

  int _activeSheet = 0;
  int get activeSheetIndex => _activeSheet;

  Worksheet? get currentSheet => _sheets.isEmpty ? null : _sheets[_activeSheet];

  List<List<SheetCell?>> get currentRows => currentSheet?.rows ?? const [];

  /// Cached per sheet: the grid asks on every build.
  int? _columnCount;
  int get columnCount => _columnCount ??= currentSheet?.columnCount ?? 0;

  SheetGeometry? _geometry;

  /// Where the current sheet's rows and columns sit; cached per sheet.
  SheetGeometry get geometry => _geometry ??= SheetGeometry(
        currentSheet ?? const Worksheet(name: '', rows: []),
        rowCount: currentRows.length,
        columnCount: columnCount,
        minFrozenRows: _freezeTopRow ? 1 : 0,
      );

  bool _freezeTopRow = false;

  /// Whether the reader keeps the sheet's top row on screen, whatever the
  /// file froze. Applies to every sheet; reported in the position.
  bool get freezeTopRow => _freezeTopRow;
  set freezeTopRow(bool value) {
    if (value == _freezeTopRow) return;
    _freezeTopRow = value;
    _geometry = null;
    notifyListeners();
    onPositionChanged?.call(position);
  }

  /// Whether the current sheet's file already froze rows at the top, so
  /// [freezeTopRow] changes nothing on it.
  bool get sheetFreezesRows => frozenRows > 0;

  CellMatch? _target;

  /// The cell [goTo] went to, marked until the next search or sheet
  /// switch.
  CellMatch? get goToTarget => _target;

  bool isGoToTarget(int row, int column) => _target?.row == row && _target?.column == column;

  /// Goes to what [reference] names: a cell on this sheet (`D120`), a cell
  /// on another (`Sheet2!B3`, `'My Sheet'!B3`), or a sheet by name. Sheet
  /// names match in any case. The cell is scrolled to the top left and
  /// marked ([goToTarget]). False when there's no such cell or sheet.
  bool goTo(String reference) {
    final text = reference.trim();
    if (text.isEmpty) return false;
    final sheetOnly = _sheetIndexNamed(text.replaceAll(RegExp(r"^'|'$"), '').replaceAll("''", "'"));
    if (sheetOnly != null) {
      switchSheet(sheetOnly);
      return true;
    }
    final place = _locate(text, ignoreCase: true);
    if (place == null) return false;
    _goToPlace(place.$1, place.$2);
    _target = place.$2;
    notifyListeners();
    return true;
  }

  int? _sheetIndexNamed(String name) {
    final lower = name.toLowerCase();
    final index = _sheets.indexWhere((sheet) => sheet.name.toLowerCase() == lower);
    return index < 0 ? null : index;
  }
  int get frozenRows => currentSheet?.frozenRows ?? 0;
  int get frozenColumns => currentSheet?.frozenColumns ?? 0;

  /// Parses an `.xlsx`, off the UI isolate, after [ZipSafetyGuard] has
  /// checked it. Sheets the author hid stay hidden, as in Excel - unless
  /// every sheet is, when showing nothing would be worse.
  Future<void> loadXlsx(Uint8List bytes) async {
    try {
      switch (ZipSafetyGuard.check(bytes)) {
        case ZipSafetyResult.tooLarge:
          _error = DocumentLoadError.tooLarge;
        case ZipSafetyResult.corrupted:
          _error = DocumentLoadError.corrupted;
        case ZipSafetyResult.safe:
          final workbook = await Isolate.run(() => XlsxReader.read(bytes));
          if (_disposed) return;
          final visible = [
            for (final sheet in workbook.sheets)
              if (sheet.visibility == SheetVisibility.visible) sheet,
          ];
          _setSheets(visible.isEmpty ? workbook.sheets : visible);
      }
    } catch (_) {
      _error = DocumentLoadError.corrupted;
    }
    if (_disposed) return;
    _loaded = true;
    notifyListeners();
  }

  /// Parses CSV bytes (UTF-8, else Latin-1) into one sheet, off the UI
  /// isolate.
  Future<void> loadCsv(Uint8List bytes) async {
    if (bytes.length > maxCsvBytes) {
      _error = DocumentLoadError.tooLarge;
    } else {
      try {
        final workbook = await Isolate.run(() => CsvReader.read(decodeTextBytes(bytes)));
        if (_disposed) return;
        _setSheets(workbook.sheets);
      } catch (_) {
        _error = DocumentLoadError.corrupted;
      }
    }
    if (_disposed) return;
    _loaded = true;
    notifyListeners();
  }

  /// For a caller that refuses a file by its size before reading it (e.g.
  /// a CSV over [maxCsvBytes]): records [DocumentLoadError.tooLarge].
  void rejectAsTooLarge() {
    _error = DocumentLoadError.tooLarge;
    _loaded = true;
    notifyListeners();
  }

  void _setSheets(List<Worksheet> sheets) {
    _sheets = sheets;
    _activeSheet = _initialSheetIndex < sheets.length ? _initialSheetIndex : 0;
    _columnCount = null;
    _geometry = null;
  }

  /// Shows another sheet; clears the search, which was for the old one.
  void switchSheet(int index) {
    if (index < 0 || index >= _sheets.length) return;
    if (index != _activeSheet) {
      // A different sheet gets a new grid, which jumps to the offsets
      // restored at open - reported as a scroll unless they're 0, when
      // nothing reports at all. Without this reset the cache would still
      // hold the previous sheet's offsets and report them for this sheet.
      // Re-selecting the current sheet keeps its grid and offsets.
      _lastVerticalOffset = 0;
      _lastHorizontalOffset = 0;
      // The offsets restored at open belong to the sheet it opened on; a
      // new sheet's grid starts at the top.
      initialVerticalOffset = 0;
      initialHorizontalOffset = 0;
    }
    _activeSheet = index;
    _columnCount = null;
    _geometry = null;
    _target = null;
    _resetSearch();
    notifyListeners();
    // Not [position]: the old sheet's grid is still attached and would
    // report its offsets for this sheet.
    onPositionChanged?.call(_positionAt(_lastVerticalOffset, _lastHorizontalOffset));
  }

  double _zoom = 1;

  /// Grid zoom factor; cells, headers and text scale with it.
  double get zoom => _zoom;
  bool get canZoomIn => _zoom < maxZoom;
  bool get canZoomOut => _zoom > minZoom;

  void zoomIn() => _setZoom(_zoom + zoomStep);
  void zoomOut() => _setZoom(_zoom - zoomStep);

  void _setZoom(double value) {
    _zoom = value.clamp(minZoom, maxZoom);
    notifyListeners();
  }

  void _captureOffsets() {
    if (verticalController.hasClients) _lastVerticalOffset = verticalController.offset;
    if (horizontalController.hasClients) _lastHorizontalOffset = horizontalController.offset;
  }

  /// The grid reports every scroll here.
  void onScrolled() {
    _captureOffsets();
    onPositionChanged?.call(position);
  }

  /// Stored at 1x zoom, so a position survives a zoom change. `row` and
  /// `column` are the sheet's (zero-based) row and column at the top left.
  ReadingPosition get position {
    _captureOffsets();
    return _positionAt(_lastVerticalOffset, _lastHorizontalOffset);
  }

  ReadingPosition _positionAt(double verticalPixels, double horizontalPixels) {
    final grid = geometry;
    final vertical = verticalPixels / _zoom;
    final horizontal = horizontalPixels / _zoom;
    return {
      PositionKeys.sheetIndex: _activeSheet,
      PositionKeys.row: grid.visibleRows.isEmpty ? 0 : grid.visibleRows[grid.visibleRowAtScrollOffset(vertical)],
      PositionKeys.column:
          grid.visibleColumns.isEmpty ? 0 : grid.visibleColumns[grid.visibleColumnAtScrollOffset(horizontal)],
      PositionKeys.verticalOffset: vertical,
      PositionKeys.horizontalOffset: horizontal,
      if (_freezeTopRow) PositionKeys.freezeTopRow: true,
    };
  }

  String _query = '';
  String get searchQuery => _query;

  List<CellMatch> _matches = const [];
  List<CellMatch> get matches => _matches;

  /// [matches] by row, for the grid's per-cell highlight lookup.
  Map<int, Set<int>> _matchColumnsByRow = const {};

  bool isMatch(int row, int column) => _matchColumnsByRow[row]?.contains(column) ?? false;

  bool isCurrentMatch(int row, int column) {
    if (_currentMatch < 0) return false;
    final match = _matches[_currentMatch];
    return match.row == row && match.column == column;
  }

  int _currentMatch = -1;

  /// Position within [matches], or -1 when there are none.
  int get currentMatchIndex => _currentMatch;

  /// Linear scan of the sheet on screen (not the whole workbook), matching
  /// each cell's shown text in any case; jumps to the first match. Hidden
  /// rows and columns are skipped, as in Excel.
  void search(String query) {
    _query = query;
    _target = null;
    final lower = query.toLowerCase();
    final found = <CellMatch>[];
    final layout = currentSheet?.layout ?? SheetLayout.standard;
    if (query.isNotEmpty) {
      final rows = currentRows;
      for (var r = 0; r < rows.length; r++) {
        if (layout.hiddenRows.contains(r)) continue;
        final row = rows[r];
        for (var c = 0; c < row.length; c++) {
          if (layout.hiddenColumns.contains(c)) continue;
          if ((row[c]?.text ?? '').toLowerCase().contains(lower)) found.add(CellMatch(row: r, column: c));
        }
      }
    }
    _matches = found;
    _indexMatches();
    _currentMatch = found.isEmpty ? -1 : 0;
    notifyListeners();
    if (found.isNotEmpty) jumpToCell(found.first);
  }

  void _resetSearch() {
    _query = '';
    _matches = const [];
    _matchColumnsByRow = const {};
    _currentMatch = -1;
  }

  void _indexMatches() {
    final byRow = <int, Set<int>>{};
    for (final match in _matches) {
      (byRow[match.row] ??= <int>{}).add(match.column);
    }
    _matchColumnsByRow = byRow;
  }

  void clearSearch() {
    _resetSearch();
    notifyListeners();
  }

  void nextMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch + 1) % _matches.length;
    notifyListeners();
    jumpToCell(_matches[_currentMatch]);
  }

  void previousMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch - 1 + _matches.length) % _matches.length;
    notifyListeners();
    jumpToCell(_matches[_currentMatch]);
  }

  /// Follows a link to a place in the workbook: `Sheet2!B3`,
  /// `'My Sheet'!B3:C4` or `B3` (this sheet). Switches sheet if needed, then
  /// scrolls there once the sheet is on screen. Returns false when the
  /// place isn't a visible sheet's cell (e.g. a defined name).
  bool openInternalLink(String location) {
    final place = _locate(location, ignoreCase: false);
    if (place == null) return false;
    _goToPlace(place.$1, place.$2);
    return true;
  }

  /// A place in the workbook -> (sheet index, cell); null when it isn't one.
  /// The sheet part is optional (this sheet) and must end in `!`; a range
  /// gives its first cell.
  (int, CellMatch)? _locate(String location, {required bool ignoreCase}) {
    final match = _place.firstMatch(location.trim());
    if (match == null) return null;
    final sheetName = match.group(1)?.replaceAll("''", "'") ?? match.group(2);
    var column = 0;
    for (final unit in match.group(3)!.toUpperCase().codeUnits) {
      column = column * 26 + (unit - 0x40);
    }
    final row = int.parse(match.group(4)!);
    if (row < 1 || row > 1048576 || column > 16384) return null;
    final index = sheetName == null
        ? _activeSheet
        : ignoreCase
            ? _sheetIndexNamed(sheetName) ?? -1
            : _sheets.indexWhere((sheet) => sheet.name == sheetName);
    if (index < 0) return null;
    return (index, CellMatch(row: row - 1, column: column - 1));
  }

  static final _place = RegExp(
    r"^(?:(?:'((?:[^']|'')+)'|([^!']+))!)?\$?([A-Za-z]{1,3})\$?(\d+)(?::\$?[A-Za-z]{1,3}\$?\d+)?$",
  );

  void _goToPlace(int index, CellMatch cell) {
    if (index != _activeSheet) {
      switchSheet(index);
      // The new sheet's grid attaches the scroll controllers after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) jumpToCell(cell);
      });
    } else {
      jumpToCell(cell);
    }
  }

  /// Scrolls [cell] to the top left (frozen rows/columns don't scroll).
  void jumpToCell(CellMatch cell) {
    final grid = geometry;
    final row = grid.visibleIndexOfRow(cell.row);
    final column = grid.visibleIndexOfColumn(cell.column);
    if (row != null && verticalController.hasClients) {
      final target = (grid.scrollOffsetOfRow(row) * _zoom).clamp(0.0, verticalController.position.maxScrollExtent);
      verticalController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
    }
    if (column != null && horizontalController.hasClients) {
      final target =
          (grid.scrollOffsetOfColumn(column) * _zoom).clamp(0.0, horizontalController.position.maxScrollExtent);
      horizontalController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    verticalController.dispose();
    horizontalController.dispose();
    super.dispose();
  }
}
