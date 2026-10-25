import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/document_controller.dart';
import '../common/document_format.dart';
import '../common/reader_contract.dart';
import '../common/text_decoding.dart';
import '../common/zip_safety_guard.dart';
import '../engines/sheets/csv_reader.dart';
import '../engines/sheets/workbook.dart';
import '../engines/sheets/xlsx_reader.dart';
import '../plain_text/plain_text_controller.dart';
import 'cell_match.dart';
import 'sheet_geometry.dart';

/// Loads an Excel workbook (`.xlsx`) or a CSV file for [SpreadsheetView]:
/// its sheets (a CSV has one), the sheet on screen, zoom, search and
/// scrolling.
///
/// Rows and columns take the sizes stored in the file, and hidden ones stay
/// hidden. [location] counts the sheet's rows; [goToCell] jumps to a cell
/// or sheet by reference (`D120`, `Sheet2!B3`); [freezeTopRow] keeps the
/// header row on screen in a sheet whose file froze none. A search matches
/// cells, as Excel's Find does: [DocumentSearchState.matchCount] is the
/// number of matching cells on the sheet on screen.
///
/// The [position] is `{sheet_index, row, column, vertical_offset,
/// horizontal_offset}`, with offsets at zoom 1, plus `freeze_top_row` when
/// it's on.
class SpreadsheetController extends DocumentController {
  /// Reopens on the sheet, at the offsets and with the header row frozen
  /// as saved in [initialPosition], if any.
  ///
  /// [format] says what [loadBytes] gets: [DocumentFormat.excel] or
  /// [DocumentFormat.csv]. Left null, a ZIP package is read as a workbook
  /// and anything else as CSV. [loadFile] goes by the file's extension.
  SpreadsheetController({ReadingPosition? initialPosition, super.onPositionChanged, this.format}) {
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

  /// What [loadBytes] reads the bytes as; null to tell from the bytes.
  final DocumentFormat? format;

  /// The width of a column with no width of its own, at zoom 1.
  static const double cellWidth = SheetGeometry.defaultColumnWidth;

  /// The height of a row with no height of its own, at zoom 1.
  static const double cellHeight = SheetGeometry.defaultRowHeight;

  /// The width of the row-number column, at zoom 1.
  static const double rowHeaderWidth = 48;

  /// Above this size a CSV is refused rather than parsed in one pass.
  static const int maxCsvBytes = 20 * 1024 * 1024;

  int _initialSheetIndex = 0;

  /// Where the grid scrolls to vertically once laid out, at zoom 1.
  double initialVerticalOffset = 0;

  /// Where the grid scrolls to horizontally once laid out, at zoom 1.
  double initialHorizontalOffset = 0;

  /// The grid's vertical scrolling.
  @internal
  final verticalController = ScrollController();

  /// The grid's horizontal scrolling.
  @internal
  final horizontalController = ScrollController();

  /// Last-known offsets, refreshed whenever the scroll views are attached.
  /// [position] uses these: once a route's scroll views detach, reading the
  /// controllers would give 0.
  double _lastVerticalOffset = 0;
  double _lastHorizontalOffset = 0;

  List<Worksheet> _sheets = const [];

  /// Visible sheets' names, in workbook order. A CSV has one.
  List<String> get sheetNames => [for (final sheet in _sheets) sheet.name];

  int _activeSheet = 0;

  /// The sheet on screen, as an index into [sheetNames].
  int get activeSheetIndex => _activeSheet;

  /// The sheet on screen; null until loaded.
  Worksheet? get currentSheet => _sheets.isEmpty ? null : _sheets[_activeSheet];

  /// The rows of the sheet on screen.
  List<List<SheetCell?>> get currentRows => currentSheet?.rows ?? const [];

  /// Cached per sheet: the grid asks on every build.
  int? _columnCount;

  /// How many columns the sheet on screen has.
  int get columnCount => _columnCount ??= currentSheet?.columnCount ?? 0;

  SheetGeometry? _geometry;

  /// Where the current sheet's rows and columns sit; cached per sheet.
  @internal
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
    reportPosition();
  }

  /// Whether the current sheet's file already froze rows at the top, so
  /// [freezeTopRow] changes nothing on it.
  bool get sheetFreezesRows => frozenRows > 0;

  CellMatch? _target;

  /// The cell [goToCell] went to, marked until the next search or sheet
  /// switch.
  CellMatch? get goToTarget => _target;

  /// Whether the cell at [row], [column] is [goToTarget].
  bool isGoToTarget(int row, int column) => _target?.row == row && _target?.column == column;

  /// Goes to what [reference] names: a cell on this sheet (`D120`), a cell
  /// on another (`Sheet2!B3`, `'My Sheet'!B3`), or a sheet by name. Sheet
  /// names match in any case. The cell is scrolled to the top left and
  /// marked ([goToTarget]). False when there's no such cell or sheet.
  bool goToCell(String reference) {
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

  /// Rows the file froze at the top of the sheet on screen.
  int get frozenRows => currentSheet?.frozenRows ?? 0;

  /// Columns the file froze at the left of the sheet on screen.
  int get frozenColumns => currentSheet?.frozenColumns ?? 0;

  /// What the file being loaded is, from its extension.
  DocumentFormat? _fileFormat;

  DocumentFormat? get _expected => _fileFormat ?? format;

  /// A CSV file over [maxCsvBytes] is refused before it is read.
  @override
  int get maxFileBytes => _expected == DocumentFormat.csv ? maxCsvBytes : super.maxFileBytes;

  @override
  Future<void> loadFile(String path) {
    _fileFormat = switch (DocumentFormat.fromPath(path)) {
      final format? when format == DocumentFormat.excel || format == DocumentFormat.csv => format,
      _ => null,
    };
    return super.loadFile(path);
  }

  /// Loads an `.xlsx` workbook or a CSV file (see [format]).
  ///
  /// A workbook passes [ZipSafetyGuard] and is parsed off the UI isolate.
  /// Sheets the author hid stay hidden, as in Excel, unless every sheet is
  /// hidden, when showing nothing would be worse. CSV must be text; it is
  /// decoded as UTF-8, falling back to Latin-1.
  @override
  Future<void> loadBytes(Uint8List bytes) async {
    markLoading();
    final isWorkbook = switch (_expected) {
      DocumentFormat.excel => true,
      DocumentFormat.csv => false,
      _ => bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04,
    };
    try {
      if (isWorkbook) {
        switch (ZipSafetyGuard.check(bytes)) {
          case ZipSafetyResult.tooLarge:
            markFailed(DocumentLoadError.tooLarge);
            return;
          case ZipSafetyResult.corrupted:
            markFailed(DocumentLoadError.corrupted);
            return;
          case ZipSafetyResult.safe:
            final workbook = await Isolate.run(() => XlsxReader.read(bytes));
            if (isDisposed) return;
            final visible = [
              for (final sheet in workbook.sheets)
                if (sheet.visibility == SheetVisibility.visible) sheet,
            ];
            _setSheets(visible.isEmpty ? workbook.sheets : visible);
        }
      } else if (bytes.length > maxCsvBytes) {
        markFailed(DocumentLoadError.tooLarge);
        return;
      } else if (PlainTextController.looksBinary(bytes)) {
        markFailed(DocumentLoadError.corrupted);
        return;
      } else {
        final workbook = await Isolate.run(() => CsvReader.read(decodeTextBytes(bytes)));
        if (isDisposed) return;
        _setSheets(workbook.sheets);
      }
    } catch (_) {
      markFailed(DocumentLoadError.corrupted);
      return;
    }
    _updateLocation();
    markReady();
  }

  void _setSheets(List<Worksheet> sheets) {
    _sheets = sheets;
    _activeSheet = _initialSheetIndex < sheets.length ? _initialSheetIndex : 0;
    _columnCount = null;
    _geometry = null;
  }

  /// The sheet row (from 0) at the top of the grid.
  int get _topRow {
    final grid = geometry;
    return grid.visibleRows.isEmpty ? 0 : grid.visibleRows[grid.visibleRowAtScrollOffset(_lastVerticalOffset / _zoom)];
  }

  void _updateLocation() =>
      updateLocation(DocumentLocation(current: _topRow + 1, count: currentRows.length, unit: DocumentUnit.row));

  /// Scrolls row [number] (from 1, as Excel numbers rows) to the top.
  @override
  void goTo(int number) {
    final grid = geometry;
    if (currentRows.isEmpty || !verticalController.hasClients) return;
    final row = grid.visibleIndexOfRow(number.clamp(1, currentRows.length) - 1);
    if (row == null) return;
    final target = (grid.scrollOffsetOfRow(row) * _zoom).clamp(0.0, verticalController.position.maxScrollExtent);
    verticalController.jumpTo(target);
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
    _updateLocation();
    notifyListeners();
    // Not [position]: the old sheet's grid is still attached and would
    // report its offsets for this sheet.
    if (!isDisposed) onPositionChanged?.call(_positionAt(_lastVerticalOffset, _lastHorizontalOffset));
  }

  double _zoom = 1;

  /// Grid zoom factor; cells, headers and text scale with it.
  @override
  double get zoom => _zoom;

  @override
  double get minZoom => 0.75;

  @override
  double get maxZoom => 2;

  @override
  void setZoom(double zoom) {
    zoom = zoom.clamp(minZoom, maxZoom);
    if (zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
  }

  void _captureOffsets() {
    if (verticalController.hasClients) _lastVerticalOffset = verticalController.offset;
    if (horizontalController.hasClients) _lastHorizontalOffset = horizontalController.offset;
  }

  /// [SpreadsheetView] reports every scroll here.
  @internal
  void onScrolled() {
    _captureOffsets();
    _updateLocation();
    reportPosition();
  }

  /// Stored at zoom 1, so a position survives a zoom change. `row` and
  /// `column` are the sheet's (zero-based) row and column at the top left.
  @override
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
      PositionKeys.column: grid.visibleColumns.isEmpty
          ? 0
          : grid.visibleColumns[grid.visibleColumnAtScrollOffset(horizontal)],
      PositionKeys.verticalOffset: vertical,
      PositionKeys.horizontalOffset: horizontal,
      if (_freezeTopRow) PositionKeys.freezeTopRow: true,
    };
  }

  String _query = '';

  /// The text being searched for; empty when there's no search.
  String get searchQuery => _query;

  List<CellMatch> _matches = const [];

  /// The matching cells of the sheet on screen, row by row.
  List<CellMatch> get matches => _matches;

  /// [matches] by row, for the grid's per-cell highlight lookup.
  Map<int, Set<int>> _matchColumnsByRow = const {};

  /// Whether the cell at [row], [column] matches the search.
  bool isMatch(int row, int column) => _matchColumnsByRow[row]?.contains(column) ?? false;

  /// Whether the cell at [row], [column] is the current match.
  bool isCurrentMatch(int row, int column) {
    if (_currentMatch < 0) return false;
    final match = _matches[_currentMatch];
    return match.row == row && match.column == column;
  }

  int _currentMatch = -1;

  /// Position within [matches], or -1 when there are none.
  int get currentMatchIndex => _currentMatch;

  /// Finds the cells of the sheet on screen (not the whole workbook) whose
  /// shown text contains [query], ignoring case, and jumps to the first.
  /// Hidden rows and columns are skipped, as in Excel.
  @override
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
    _updateSearch();
    notifyListeners();
    if (found.isNotEmpty) jumpToCell(found.first);
  }

  void _updateSearch() =>
      updateSearch(DocumentSearchState(query: _query, matchCount: _matches.length, currentMatch: _currentMatch));

  void _resetSearch() {
    _query = '';
    _matches = const [];
    _matchColumnsByRow = const {};
    _currentMatch = -1;
    _updateSearch();
  }

  void _indexMatches() {
    final byRow = <int, Set<int>>{};
    for (final match in _matches) {
      (byRow[match.row] ??= <int>{}).add(match.column);
    }
    _matchColumnsByRow = byRow;
  }

  @override
  void clearSearch() {
    _resetSearch();
    notifyListeners();
  }

  @override
  void nextMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch + 1) % _matches.length;
    _updateSearch();
    notifyListeners();
    jumpToCell(_matches[_currentMatch]);
  }

  @override
  void previousMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch - 1 + _matches.length) % _matches.length;
    _updateSearch();
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
        if (!isDisposed) jumpToCell(cell);
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
      final target = (grid.scrollOffsetOfColumn(column) * _zoom).clamp(
        0.0,
        horizontalController.position.maxScrollExtent,
      );
      horizontalController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
    }
  }

  @override
  void dispose() {
    verticalController.dispose();
    horizontalController.dispose();
    super.dispose();
  }
}
