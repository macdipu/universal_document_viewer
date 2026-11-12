import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/document_controller.dart';
import '../common/document_format.dart';
import '../common/reader_contract.dart';
import '../common/text_decoding.dart';
import '../common/zip_safety_guard.dart';
import '../engines/spreadsheet/csv_reader.dart';
import '../engines/spreadsheet/workbook.dart';
import '../engines/spreadsheet/xlsx_reader.dart';
import 'cell_match.dart';
import 'grid_selection.dart';
import 'sheet_density.dart';
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
  ///
  /// [density] fixes how roomy the grid is; left null, [SpreadsheetView]
  /// picks it from the input device (touch on phones, compact for a mouse
  /// on a desktop).
  SpreadsheetController({ReadingPosition? initialPosition, super.onPositionChanged, this.format, SheetDensity? density})
    : _density = density {
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

  /// The width of a column with no width of its own, at zoom 1, in
  /// [SheetDensity.touch] (see [metrics] for the density in use).
  static const double cellWidth = 104;

  /// The height of a row with no height of its own, at zoom 1, in
  /// [SheetDensity.touch].
  static const double cellHeight = 36;

  /// The height of the column-letter header row, at zoom 1, in
  /// [SheetDensity.touch]: a 44 dp touch target.
  static const double headerHeight = 44;

  /// The width of the row-number column, at zoom 1, in
  /// [SheetDensity.touch].
  static const double rowHeaderWidth = 40;

  SheetDensity? _density;
  SheetDensity _autoDensity = SheetDensity.touch;

  /// The density in use: the one given, else the one [SpreadsheetView]
  /// chose for the input device.
  SheetDensity get density => _density ?? _autoDensity;

  /// Fixes the density, or null to let the view choose.
  set density(SheetDensity? value) => _changeDensity(() => _density = value);

  /// [SpreadsheetView] reports the input device here. Ignored while a
  /// density was given.
  @internal
  void setAutoDensity(SheetDensity value, {bool notify = true}) {
    if (value == _autoDensity) return;
    if (notify) {
      _changeDensity(() => _autoDensity = value);
    } else {
      _autoDensity = value;
      _geometry = null;
    }
  }

  /// The sizes of the density in use.
  SheetMetrics get metrics => SheetMetrics.of(density);

  /// Applies a density change and keeps the row at the top where it was.
  void _changeDensity(void Function() change) {
    final before = density;
    final grid = _geometry;
    final topRow = grid == null || !verticalController.hasClients || currentRows.isEmpty ? null : _topRow;
    change();
    if (density == before) return;
    _geometry = null;
    notifyListeners();
    if (topRow == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isDisposed || !verticalController.hasClients) return;
      final visible = geometry.visibleIndexOfRow(topRow);
      if (visible == null) return;
      verticalController.jumpTo(
        (geometry.scrollOffsetOfRow(visible) * _zoom).clamp(0.0, verticalController.position.maxScrollExtent),
      );
    });
  }

  /// Widths (1x pixels) the reader gave columns, by sheet index then
  /// column; not saved to the file and cleared when another file loads.
  final _columnWidthOverrides = <int, Map<int, double>>{};

  /// Whether [column] of the sheet on screen has a width the reader set.
  bool hasColumnWidthOverride(int column) => _columnWidthOverrides[_activeSheet]?.containsKey(column) ?? false;

  /// Sets [column]'s width on screen (1x pixels, 24 to 800), or restores
  /// the file's with null. View only: the file is never changed.
  void setColumnWidth(int column, double? width) {
    final map = _columnWidthOverrides.putIfAbsent(_activeSheet, () => {});
    if (width == null) {
      if (map.remove(column) == null) return;
    } else {
      final clamped = width.clamp(24.0, 800.0);
      if (map[column] == clamped) return;
      map[column] = clamped;
    }
    _geometry = null;
    notifyListeners();
  }

  /// Fits [column] to its longest text among the first 1,000 rows
  /// (Excel's double-click on a header border). [baseStyle] is the text
  /// style the cells inherit (the view passes its ambient one, so the app's
  /// font is what gets measured).
  void autoFitColumn(int column, {TextStyle? baseStyle}) {
    final rows = currentRows;
    final painter = TextPainter(textDirection: TextDirection.ltr, maxLines: 1);
    var widest = 0.0;
    try {
      for (var r = 0; r < rows.length && r < 1000; r++) {
        if (column >= rows[r].length) continue;
        final cell = rows[r][column];
        if (cell == null || cell.text.isEmpty) continue;
        painter
          ..text = TextSpan(
            text: cell.text,
            style: (baseStyle ?? const TextStyle()).copyWith(
              fontSize: SheetGeometry.fontPixelsOf(cell.style.fontSize),
              fontWeight: cell.style.bold ? FontWeight.bold : FontWeight.normal,
              fontStyle: cell.style.italic ? FontStyle.italic : FontStyle.normal,
            ),
          )
          ..layout();
        if (painter.width > widest) widest = painter.width;
      }
    } finally {
      painter.dispose();
    }
    // A little extra so the last letter never sits on the ellipsis.
    setColumnWidth(column, widest + 2 * metrics.paddingX + 6);
  }

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
    fittedRowHeights: currentSheet == null
        ? const {}
        : _fittedRowHeights[(_activeSheet, density)] ??= SheetGeometry.fitWrappedRows(currentSheet!, metrics: metrics),
    columnWidthOverrides: _columnWidthOverrides[_activeSheet] ?? const {},
    metrics: metrics,
  );

  /// [SheetGeometry.fitWrappedRows] per sheet index and density, measured
  /// once.
  final _fittedRowHeights = <(int, SheetDensity), Map<int, double>>{};

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

  final _selection = ValueNotifier<GridSelection?>(null);

  /// The cells selected on the sheet on screen, or null. Cleared when the
  /// sheet changes or a file loads. Held in sheet coordinates, so it stays
  /// put while the grid scrolls or zooms.
  ValueListenable<GridSelection?> get selection => _selection;

  /// Selects [selection] (null clears it). Cells outside the sheet are
  /// kept inside it.
  void select(GridSelection? selection) {
    if (selection == null || currentRows.isEmpty || columnCount == 0) {
      _selection.value = null;
      return;
    }
    final lastRow = currentRows.length - 1;
    final lastColumn = columnCount - 1;
    int row(int r) => r.clamp(0, lastRow);
    int column(int c) => c.clamp(0, lastColumn);
    _selection.value = switch (selection.kind) {
      GridSelectionKind.cell => GridSelection.cell(row(selection.activeRow), column(selection.activeColumn)),
      GridSelectionKind.range => GridSelection.range(
        anchorRow: row(selection.anchorRow),
        anchorColumn: column(selection.anchorColumn),
        activeRow: row(selection.activeRow),
        activeColumn: column(selection.activeColumn),
      ),
      GridSelectionKind.row => GridSelection.row(row(selection.index)),
      GridSelectionKind.column => GridSelection.column(column(selection.index)),
      GridSelectionKind.all => const GridSelection.all(),
    };
  }

  /// Selections bigger than this can't be copied, so a select-all on a huge
  /// sheet can't fill memory.
  static const maxCopiedCells = 1000000;

  /// The selected cells as the text a spreadsheet would paste: rows on
  /// separate lines, cells tab-separated (TSV), the shown text of each
  /// (formula cells give their result). A cell holding a tab, a line break
  /// or a quote is quoted, as Excel does, so pasting keeps the grid's
  /// shape; a single cell is copied as it reads. A whole row, column or
  /// select-all drops trailing blank rows and columns. Null when nothing
  /// is selected or the selection is over [maxCopiedCells].
  String? selectedText() {
    final selection = _selection.value;
    if (selection == null) return null;
    final rows = currentRows;
    final bounds = selection.bounds(rowCount: rows.length, columnCount: columnCount);
    var lastRow = bounds.lastRow;
    var lastColumn = bounds.lastColumn;
    if ((lastRow - bounds.firstRow + 1) * (lastColumn - bounds.firstColumn + 1) > maxCopiedCells) return null;
    String textAt(int r, int c) => r < rows.length && c < rows[r].length ? rows[r][c]?.text ?? '' : '';
    if (selection.kind == GridSelectionKind.cell) return textAt(selection.activeRow, selection.activeColumn);
    final wholeLines = selection.kind != GridSelectionKind.range;
    if (wholeLines) {
      while (lastRow > bounds.firstRow &&
          [for (var c = bounds.firstColumn; c <= lastColumn; c++) textAt(lastRow, c)].every((t) => t.isEmpty)) {
        lastRow--;
      }
      while (lastColumn > bounds.firstColumn &&
          [for (var r = bounds.firstRow; r <= lastRow; r++) textAt(r, lastColumn)].every((t) => t.isEmpty)) {
        lastColumn--;
      }
    }
    String field(String text) => text.contains(RegExp('[\t\r\n"]')) ? '"${text.replaceAll('"', '""')}"' : text;
    return [
      for (var r = bounds.firstRow; r <= lastRow; r++)
        [for (var c = bounds.firstColumn; c <= lastColumn; c++) field(textAt(r, c))].join('\t'),
    ].join('\n');
  }

  /// Clears the selection.
  void clearSelection() => _selection.value = null;

  /// Selects every cell of the sheet's used range.
  void selectAll() => select(const GridSelection.all());

  /// Moves the active cell by [rows] and [columns] visible rows and columns
  /// (hidden ones are skipped), keeping the selection inside the sheet.
  /// With [extend] the anchor stays and the selection grows to a range.
  /// With no selection, the first visible cell is selected instead.
  void moveSelection({int rows = 0, int columns = 0, bool extend = false}) {
    final current = _selection.value;
    final grid = geometry;
    if (grid.visibleRows.isEmpty || grid.visibleColumns.isEmpty) return;
    if (current == null) {
      select(GridSelection.cell(grid.visibleRows.first, grid.visibleColumns.first));
    } else {
      final row = _step(grid.visibleRows, grid.visibleIndexOfRow(current.activeRow), rows);
      final column = _step(grid.visibleColumns, grid.visibleIndexOfColumn(current.activeColumn), columns);
      _moveTo(current, row, column, extend);
    }
    _revealActive();
  }

  /// Moves the active cell to [row] and/or [column] (sheet indices; null
  /// keeps the current one), or to the nearest visible one if hidden.
  void moveSelectionTo({int? row, int? column, bool extend = false}) {
    final current = _selection.value;
    final grid = geometry;
    if (grid.visibleRows.isEmpty || grid.visibleColumns.isEmpty) return;
    final fromRow = current?.activeRow ?? grid.visibleRows.first;
    final fromColumn = current?.activeColumn ?? grid.visibleColumns.first;
    final targetRow = _nearestVisible(grid.visibleRows, row ?? fromRow);
    final targetColumn = _nearestVisible(grid.visibleColumns, column ?? fromColumn);
    if (current == null) {
      select(GridSelection.cell(targetRow, targetColumn));
    } else {
      _moveTo(current, targetRow, targetColumn, extend);
    }
    _revealActive();
  }

  void _moveTo(GridSelection current, int row, int column, bool extend) {
    select(extend ? current.extendedTo(row, column) : GridSelection.cell(row, column));
  }

  static int _step(List<int> visible, int? index, int delta) =>
      visible[((index ?? 0) + delta).clamp(0, visible.length - 1)];

  static int _nearestVisible(List<int> visible, int value) {
    var low = 0;
    var high = visible.length - 1;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (visible[mid] < value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return visible[low];
  }

  /// How many rows fit on the screen, for Page Up and Page Down.
  int get pageRows {
    if (!verticalController.hasClients) return 1;
    final grid = geometry;
    final window = verticalController.position.viewportDimension - (metrics.headerHeight + grid.frozenHeight) * _zoom;
    return math.max(1, (window / (metrics.rowHeight * _zoom)).floor() - 1);
  }

  void _revealActive() {
    final current = _selection.value;
    if (current != null) revealCell(current.activeRow, current.activeColumn);
  }

  /// Scrolls just far enough to bring the cell at [row], [column] (sheet
  /// indices) into view, clear of the frozen panes and the headers. Does
  /// nothing for a hidden cell or one already on screen.
  void revealCell(int row, int column) {
    final grid = geometry;
    final r = grid.visibleIndexOfRow(row);
    final c = grid.visibleIndexOfColumn(column);
    if (r != null && r >= grid.frozenRowCount && verticalController.hasClients) {
      _reveal(
        verticalController,
        start: grid.scrollOffsetOfRow(r) * _zoom,
        size: grid.rowHeight(r) * _zoom,
        pinned: (metrics.headerHeight + grid.frozenHeight) * _zoom,
      );
    }
    if (c != null && c >= grid.frozenColumnCount && horizontalController.hasClients) {
      _reveal(
        horizontalController,
        start: grid.scrollOffsetOfColumn(c) * _zoom,
        size: grid.columnWidth(c) * _zoom,
        pinned: (metrics.rowHeaderWidth + grid.frozenWidth) * _zoom,
      );
    }
  }

  static void _reveal(
    ScrollController controller, {
    required double start,
    required double size,
    required double pinned,
  }) {
    final position = controller.position;
    final window = position.viewportDimension - pinned;
    double? target;
    if (start < position.pixels) {
      target = start;
    } else if (start + size > position.pixels + window) {
      target = start + size - window;
    }
    if (target != null) controller.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

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

  /// The file being loaded is `.tsv`: split on tabs, never guess.
  bool _tabSeparated = false;

  List<String> _hiddenSheetNames = const [];

  /// Sheets the author hid (Excel's Hide), which are not among
  /// [sheetNames], so a reader can say they exist. "Very hidden" sheets,
  /// which Excel itself never lists, are left out, as are hidden sheets
  /// shown because every sheet was hidden.
  List<String> get hiddenSheetNames => _hiddenSheetNames;

  /// A CSV file over [maxCsvBytes] is refused before it is read.
  @override
  int get maxFileBytes => _expected == DocumentFormat.csv ? maxCsvBytes : super.maxFileBytes;

  @override
  Future<void> loadFile(String path) {
    _fileFormat = switch (DocumentFormat.fromPath(path)) {
      final format? when format == DocumentFormat.excel || format == DocumentFormat.csv => format,
      _ => null,
    };
    _tabSeparated = path.toLowerCase().endsWith('.tsv');
    return super.loadFile(path);
  }

  /// Loads an `.xlsx`/`.xlsm` workbook or a CSV/TSV file (see [format]).
  ///
  /// A workbook passes [ZipSafetyGuard] and is parsed off the UI isolate;
  /// macros in an `.xlsm` are never read or run. A password-protected
  /// workbook fails with [DocumentLoadError.passwordRequired]. Sheets the
  /// author hid stay hidden, as in Excel, and are listed in
  /// [hiddenSheetNames], unless every sheet is hidden, when showing nothing
  /// would be worse. CSV must be text; it is decoded as UTF-8, falling back
  /// to Latin-1. A `.tsv` file is split on tabs.
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
            markFailed(
              ZipSafetyGuard.isEncryptedOfficeFile(bytes)
                  ? DocumentLoadError.passwordRequired
                  : DocumentLoadError.corrupted,
            );
            return;
          case ZipSafetyResult.safe:
            final workbook = await Isolate.run(() => XlsxReader.read(bytes));
            if (isDisposed) return;
            final visible = [
              for (final sheet in workbook.sheets)
                if (sheet.visibility == SheetVisibility.visible) sheet,
            ];
            _setSheets(visible.isEmpty ? workbook.sheets : visible);
            _hiddenSheetNames = visible.isEmpty
                ? const []
                : [
                    for (final sheet in workbook.sheets)
                      if (sheet.visibility == SheetVisibility.hidden) sheet.name,
                  ];
        }
      } else if (bytes.length > maxCsvBytes) {
        markFailed(DocumentLoadError.tooLarge);
        return;
      } else if (looksLikeBinary(bytes)) {
        markFailed(
          ZipSafetyGuard.isEncryptedOfficeFile(bytes)
              ? DocumentLoadError.passwordRequired
              : DocumentLoadError.corrupted,
        );
        return;
      } else {
        final delimiter = _tabSeparated ? '\t' : null;
        final workbook = await Isolate.run(() => CsvReader.read(decodeTextBytes(bytes), delimiter: delimiter));
        if (isDisposed) return;
        _setSheets(workbook.sheets);
        _hiddenSheetNames = const [];
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
    _fittedRowHeights.clear();
    _columnWidthOverrides.clear();
    _activeSheet = _initialSheetIndex < sheets.length ? _initialSheetIndex : 0;
    _columnCount = null;
    _geometry = null;
    _selection.value = null;
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
    if (currentRows.isEmpty || !verticalController.hasClients) return deferGoTo(number);
    final row = grid.visibleIndexOfRow(number.clamp(1, currentRows.length) - 1);
    if (row == null) return;
    final target = (grid.scrollOffsetOfRow(row) * _zoom).clamp(0.0, verticalController.position.maxScrollExtent);
    verticalController.jumpTo(target);
  }

  /// Shows another sheet. A search of the old sheet ends; a search of every
  /// sheet ([SheetSearchOptions.allSheets]) goes on.
  void switchSheet(int index) {
    if (index < 0 || index >= _sheets.length) return;
    final previousSheet = _activeSheet;
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
    // A selection belongs to the sheet it was made on.
    if (index != previousSheet) _selection.value = null;
    // A search of this sheet only is over; one of every sheet goes on.
    if (!_searchOptions.allSheets) _resetSearch();
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

  SheetSearchOptions _searchOptions = const SheetSearchOptions();

  /// How [search] matches. Changing them runs the current search again.
  SheetSearchOptions get searchOptions => _searchOptions;

  set searchOptions(SheetSearchOptions options) {
    if (options == _searchOptions) return;
    _searchOptions = options;
    if (_query.isNotEmpty) {
      search(_query);
    } else {
      notifyListeners();
    }
  }

  List<CellMatch> _matches = const [];

  /// The matching cells, sheet by sheet and row by row: of the sheet on
  /// screen, or of every sheet when [SheetSearchOptions.allSheets]. Each
  /// has its [CellMatch.sheet].
  List<CellMatch> get matches => _matches;

  /// [matches] by sheet, then row, for the grid's per-cell highlight.
  Map<int, Map<int, Set<int>>> _matchIndex = const {};

  /// Whether the cell at [row], [column] of the sheet on screen matches.
  bool isMatch(int row, int column) => _matchIndex[_activeSheet]?[row]?.contains(column) ?? false;

  /// Whether the cell at [row], [column] of the sheet on screen is the
  /// current match.
  bool isCurrentMatch(int row, int column) {
    if (_currentMatch < 0) return false;
    final match = _matches[_currentMatch];
    return match.row == row && match.column == column && (match.sheet ?? _activeSheet) == _activeSheet;
  }

  int _currentMatch = -1;

  /// Position within [matches], or -1 when there are none.
  int get currentMatchIndex => _currentMatch;

  /// Workbooks up to this many cells are searched at once; bigger ones in
  /// slices of [_searchSliceCells] between frames, after [_searchDelay],
  /// so typing stays responsive and a newer query cancels an older one.
  static const _syncSearchCells = 200000;
  static const _searchSliceCells = 50000;
  static const _searchDelay = Duration(milliseconds: 200);

  int _searchGeneration = 0;
  bool _searching = false;

  /// Whether a search of a big workbook is still running.
  bool get isSearching => _searching;

  /// Finds the cells whose shown text (or formula, see [searchOptions])
  /// contains [query], ignoring case unless [SheetSearchOptions.matchCase],
  /// on the sheet on screen or in every sheet, then goes to the first
  /// match on or after the sheet on screen. Hidden rows, columns and
  /// sheets are skipped, as in Excel. A big workbook is searched in slices
  /// ([isSearching] meanwhile); an empty query ends the search.
  @override
  void search(String query) {
    final generation = ++_searchGeneration;
    _query = query;
    _target = null;
    final sheets = query.isEmpty
        ? const <int>[]
        : _searchOptions.allSheets
        ? [for (var i = 0; i < _sheets.length; i++) i]
        : [if (_sheets.isNotEmpty) _activeSheet];
    var cells = 0;
    for (final index in sheets) {
      for (final row in _sheets[index].rows) {
        cells += row.length;
      }
    }
    if (cells <= _syncSearchCells) {
      _searching = false;
      final found = <CellMatch>[];
      for (final _ in _scan(sheets, query, found)) {}
      _finishSearch(found);
      return;
    }
    _searching = true;
    _matches = const [];
    _matchIndex = const {};
    _currentMatch = -1;
    updateSearch(DocumentSearchState(query: query, matchCount: 0, currentMatch: -1, isSearching: true));
    notifyListeners();
    Future<void>(() async {
      await Future<void>.delayed(_searchDelay);
      final found = <CellMatch>[];
      for (final _ in _scan(sheets, query, found)) {
        if (generation != _searchGeneration || isDisposed) return;
        await Future<void>.delayed(Duration.zero);
      }
      if (generation != _searchGeneration || isDisposed) return;
      _searching = false;
      _finishSearch(found);
    });
  }

  /// Adds the matches in [sheets] to [found], yielding after every
  /// [_searchSliceCells] cells.
  Iterable<void> _scan(List<int> sheets, String query, List<CellMatch> found) sync* {
    final options = _searchOptions;
    final needle = options.matchCase ? query : query.toLowerCase();
    var budget = _searchSliceCells;
    for (final index in sheets) {
      final sheet = _sheets[index];
      final layout = sheet.layout;
      final rows = sheet.rows;
      for (var r = 0; r < rows.length; r++) {
        if (layout.hiddenRows.contains(r)) continue;
        final row = rows[r];
        for (var c = 0; c < row.length; c++) {
          final cell = row[c];
          if (cell == null || layout.hiddenColumns.contains(c)) continue;
          var text = switch (cell.value) {
            FormulaValue(:final formula) when options.inFormulas => '=$formula',
            _ => cell.text,
          };
          if (!options.matchCase) text = text.toLowerCase();
          if (options.wholeCell ? text == needle : text.contains(needle)) {
            found.add(CellMatch(row: r, column: c, sheet: index));
          }
        }
        budget -= row.length;
        if (budget <= 0) {
          budget = _searchSliceCells;
          yield null;
        }
      }
    }
  }

  void _finishSearch(List<CellMatch> found) {
    _matches = found;
    _indexMatches();
    final here = found.indexWhere((m) => (m.sheet ?? _activeSheet) >= _activeSheet);
    _currentMatch = found.isEmpty ? -1 : (here < 0 ? 0 : here);
    _updateSearch();
    notifyListeners();
    if (_currentMatch >= 0) _goToMatch(found[_currentMatch]);
  }

  void _goToMatch(CellMatch match) => _goToPlace(match.sheet ?? _activeSheet, match);

  void _updateSearch() => updateSearch(
    DocumentSearchState(
      query: _query,
      matchCount: _matches.length,
      currentMatch: _currentMatch,
      isSearching: _searching,
    ),
  );

  void _resetSearch() {
    _searchGeneration++;
    _searching = false;
    _query = '';
    _matches = const [];
    _matchIndex = const {};
    _currentMatch = -1;
    _updateSearch();
  }

  void _indexMatches() {
    final index = <int, Map<int, Set<int>>>{};
    for (final match in _matches) {
      ((index[match.sheet ?? _activeSheet] ??= {})[match.row] ??= <int>{}).add(match.column);
    }
    _matchIndex = index;
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
    _goToMatch(_matches[_currentMatch]);
  }

  @override
  void previousMatch() {
    if (_matches.isEmpty) return;
    _currentMatch = (_currentMatch - 1 + _matches.length) % _matches.length;
    _updateSearch();
    notifyListeners();
    _goToMatch(_matches[_currentMatch]);
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

  /// Whether the system asks for no animation (Reduce Motion, "Remove
  /// animations"): scrolls then jump.
  static bool get _reduceMotion => WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  static void _scrollTo(ScrollController controller, double target) {
    if (_reduceMotion) {
      controller.jumpTo(target);
    } else {
      controller.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
    }
  }

  /// Scrolls [cell] to the top left (frozen rows/columns don't scroll).
  /// Jumps, without animating, when the system asks for reduced motion.
  void jumpToCell(CellMatch cell) {
    final grid = geometry;
    final row = grid.visibleIndexOfRow(cell.row);
    final column = grid.visibleIndexOfColumn(cell.column);
    if (row != null && verticalController.hasClients) {
      final target = (grid.scrollOffsetOfRow(row) * _zoom).clamp(0.0, verticalController.position.maxScrollExtent);
      _scrollTo(verticalController, target);
    }
    if (column != null && horizontalController.hasClients) {
      final target = (grid.scrollOffsetOfColumn(column) * _zoom).clamp(
        0.0,
        horizontalController.position.maxScrollExtent,
      );
      _scrollTo(horizontalController, target);
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    verticalController.dispose();
    horizontalController.dispose();
    super.dispose();
  }
}
