import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../common/reader_contract.dart';
import '../common/text_decoding.dart';
import '../engines/sheets/csv_reader.dart';
import '../engines/sheets/workbook.dart';
import '../engines/sheets/xlsx_reader.dart';
import '../sheets/cell_border.dart';
import '../sheets/spreadsheet_controller.dart';
import 'offscreen_render.dart';
import 'thumbnail_renderer.dart';
import 'thumbnail_sources.dart';

/// The top-left corner of a spreadsheet's first visible sheet as a small
/// grid on a portrait card, like the sheet reader's: column letters, row
/// numbers, cell text with its fill, colour, bold and italic. With a saved
/// position, the saved sheet (`sheet_index`, among the sheets the reader
/// shows) from its saved top-left cell (`row`, `column`) instead. Excel
/// files pass [ZipSafetyGuard]; a CSV the reader would refuse (too large)
/// gets no thumbnail, and only its first lines are read unless the saved
/// row is below the first.
class SheetThumbnailRenderer implements ThumbnailRenderer {
  const SheetThumbnailRenderer.xlsx() : _csv = false;
  const SheetThumbnailRenderer.csv() : _csv = true;

  final bool _csv;

  /// A 3:4 card; the grid is drawn at Excel's own cell sizes on it.
  static const Size _card = Size(420, 560);

  @override
  Future<ui.Image?> render(String path, {required int width, ReadingPosition? position}) async {
    final at = SheetPosition(
      sheet: positionIndex(position, PositionKeys.sheetIndex) ?? 0,
      row: positionIndex(position, PositionKeys.row) ?? 0,
      column: positionIndex(position, PositionKeys.column) ?? 0,
    );
    final corner = _csv ? await _csvCorner(path, at) : await parseOfficeFile(path, (bytes) => _xlsxCorner(bytes, at));
    if (corner == null) return null;
    return renderOffscreen(_SheetCornerView(corner), size: _card, width: width);
  }

  static Future<SheetCorner?> _csvCorner(String path, SheetPosition at) async {
    SheetCorner? corner(Uint8List bytes) => SheetCorner.of(CsvReader.read(decodeTextBytes(bytes)), at: at);
    // A corner further down than the first row needs the whole file: the
    // head may not reach it.
    if (at.row > 0) {
      return parseTextFile<SheetCorner?>(path, maxBytes: SpreadsheetController.maxCsvBytes, parse: corner);
    }
    final head = await readTextHead(path, maxBytes: SpreadsheetController.maxCsvBytes);
    if (head == null) return null;
    return Isolate.run(() => corner(head));
  }

  static SheetCorner? _xlsxCorner(Uint8List bytes, SheetPosition at) => SheetCorner.of(XlsxReader.read(bytes), at: at);
}

/// Where a sheet thumbnail starts: a sheet among those the reader shows,
/// and the zero-based row and column at its top left.
class SheetPosition {
  const SheetPosition({this.sheet = 0, this.row = 0, this.column = 0});

  final int sheet;
  final int row;
  final int column;
}

/// The cells of a sheet that fit on the thumbnail card - all that comes
/// back from the parsing isolate, however big the sheet.
class SheetCorner {
  const SheetCorner({
    required this.columns,
    required this.columnWidths,
    required this.rows,
    required this.rowHeights,
    required this.cells,
  });

  /// Sheet indices of the visible columns/rows shown, in order.
  final List<int> columns;
  final List<int> rows;

  /// In pixels at Excel's default size (a 8.43-character column is 64 px,
  /// a 15 pt row 20 px).
  final List<double> columnWidths;
  final List<double> rowHeights;

  /// `cells[r][c]` is row `rows[r]`, column `columns[c]`.
  final List<List<SheetCell?>> cells;

  static const double rowHeaderWidth = 30;
  static const double headerHeight = 20;

  /// The corner of a sheet at [at], as much of it as fills
  /// [SheetThumbnailRenderer]'s card. The sheet is counted as the reader
  /// counts them - the visible ones, or all when none is visible - and is
  /// the first sheet's top left when [at] names none of them. Null without
  /// a sheet.
  static SheetCorner? of(Workbook workbook, {SheetPosition at = const SheetPosition()}) {
    final visible = workbook.sheets.where((s) => s.visibility == SheetVisibility.visible).toList();
    final shown = visible.isEmpty ? workbook.sheets : visible;
    if (shown.isEmpty) return null;
    if (at.sheet >= shown.length) at = const SheetPosition();
    final sheet = shown[at.sheet];
    final layout = sheet.layout;
    final columns = <int>[];
    final columnWidths = <double>[];
    var x = rowHeaderWidth;
    for (var c = at.column; x < SheetThumbnailRenderer._card.width && c < at.column + 100; c++) {
      if (layout.hiddenColumns.contains(c)) continue;
      final characters = layout.columnWidth(c);
      if (characters <= 0) continue;
      final width = characters * 7 + 5;
      columns.add(c);
      columnWidths.add(width);
      x += width;
    }
    final rows = <int>[];
    final rowHeights = <double>[];
    var y = headerHeight;
    for (var r = at.row; y < SheetThumbnailRenderer._card.height && r < at.row + 200; r++) {
      if (layout.hiddenRows.contains(r)) continue;
      final points = layout.rowHeight(r);
      if (points <= 0) continue;
      final height = points * 4 / 3;
      rows.add(r);
      rowHeights.add(height);
      y += height;
    }
    return SheetCorner(
      columns: columns,
      columnWidths: columnWidths,
      rows: rows,
      rowHeights: rowHeights,
      cells: [
        for (final r in rows)
          [
            for (final c in columns)
              if (r < sheet.rows.length && c < sheet.rows[r].length) sheet.rows[r][c] else null,
          ],
      ],
    );
  }
}

class _SheetCornerView extends StatelessWidget {
  const _SheetCornerView(this.corner);

  final SheetCorner corner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = Border(
      right: BorderSide(color: scheme.outlineVariant, width: 0.5),
      bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
    );
    final headerStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    Widget header(String label, double width, double height) => Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: scheme.surfaceContainer, border: border),
          child: Text(label, maxLines: 1, overflow: TextOverflow.clip, style: headerStyle),
        );

    return OverflowBox(
      alignment: Alignment.topLeft,
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              header('', SheetCorner.rowHeaderWidth, SheetCorner.headerHeight),
              for (var c = 0; c < corner.columns.length; c++)
                header(_columnLabel(corner.columns[c]), corner.columnWidths[c], SheetCorner.headerHeight),
            ],
          ),
          for (var r = 0; r < corner.rows.length; r++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                header('${corner.rows[r] + 1}', SheetCorner.rowHeaderWidth, corner.rowHeights[r]),
                for (var c = 0; c < corner.columns.length; c++)
                  _CellView(
                    corner.cells[r][c],
                    width: corner.columnWidths[c],
                    height: corner.rowHeights[r],
                    border: cellBorder(
                      corner.cells[r][c]?.style.borders ?? CellBorders.none,
                      gridline: scheme.outlineVariant,
                      automatic: Colors.black,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static String _columnLabel(int index) {
    var n = index;
    var label = '';
    do {
      label = String.fromCharCode(65 + n % 26) + label;
      n = n ~/ 26 - 1;
    } while (n >= 0);
    return label;
  }
}

class _CellView extends StatelessWidget {
  const _CellView(this.cell, {required this.width, required this.height, required this.border});

  final SheetCell? cell;
  final double width;
  final double height;
  final Border border;

  /// Excel draws its default 11 pt font about 15 px tall in a 20 px row.
  static const double _pixelsPerPoint = 12 / 11;

  @override
  Widget build(BuildContext context) {
    final style = cell?.style ?? CellStyle.plain;
    final fill = style.fillColor == null ? null : Color(style.fillColor!);
    final onFill = fill == null || fill.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      alignment: _alignment(style, cell?.value),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: fill, border: border),
      child: Text(
        cell?.text ?? '',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(
          color: style.textColor == null ? onFill : Color(style.textColor!),
          fontSize: (style.fontSize ?? 11) * _pixelsPerPoint,
          fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }

  /// Excel's "general" alignment: numbers right, booleans and errors
  /// centred, text left.
  static Alignment _alignment(CellStyle style, CellValue? value) => switch (style.horizontalAlignment) {
        HorizontalAlignment.right => Alignment.centerRight,
        HorizontalAlignment.center || HorizontalAlignment.centerContinuous => Alignment.center,
        HorizontalAlignment.general => switch (value) {
            NumberValue() || FormulaValue(cached: NumberValue()) => Alignment.centerRight,
            BoolValue() || ErrorValue() => Alignment.center,
            _ => Alignment.centerLeft,
          },
        _ => Alignment.centerLeft,
      };
}
