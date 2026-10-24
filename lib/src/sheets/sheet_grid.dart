import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
import 'package:url_launcher/url_launcher.dart';

import '../engines/sheets/workbook.dart';
import 'cell_border.dart';
import 'sheet_geometry.dart';
import 'spreadsheet_controller.dart';

/// A spreadsheet grid built lazily (only the cells on screen exist), with
/// the sheet's own column widths and row heights, hidden rows/columns left
/// out, its frozen panes pinned along with the header row and row-number
/// column, merged cells, and its text formatting. Also: a −/+ zoom pill,
/// search highlights, row/column selection with Count/Sum/Avg and Copy, a
/// cell's full value (with its formula, note and link) on tap. Cell
/// borders, conditional formatting (fills, colours, data bars) and a note
/// marker come from the file. Scrolls through the
/// controller's `verticalController`/`horizontalController`. Serves Excel
/// and CSV alike.
class SheetGrid extends StatefulWidget {
  final SpreadsheetController controller;
  final String emptyMessage;

  const SheetGrid({super.key, required this.controller, this.emptyMessage = 'No data to display'});

  @override
  State<SheetGrid> createState() => _SheetGridState();
}

class _SheetGridState extends State<SheetGrid> {
  /// The row or column picked by tapping its header; null when none.
  final _selection = ValueNotifier<GridSelection?>(null);

  void _toggleSelection(GridSelection selection) =>
      _selection.value = _selection.value == selection ? null : selection;
  late double _zoom;

  /// Merged areas in table coordinates, for the geometry they were built
  /// from.
  SheetGeometry? _mergesFor;
  Map<(int, int), _Merge> _merges = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreInitialOffsets());
    widget.controller.horizontalController.addListener(widget.controller.onScrolled);
    widget.controller.verticalController.addListener(widget.controller.onScrolled);
    // Read now, not lazily: the first read used to happen inside the zoom
    // handler, after the change, so the first zoom wasn't anchored.
    _zoom = widget.controller.zoom;
    widget.controller.addListener(_onControllerChanged);
  }

  /// Keeps the same cells in view across a zoom change: offsets scale by
  /// the zoom ratio once the resized grid has laid out (UX-32).
  void _onControllerChanged() {
    if (widget.controller.zoom != _zoom) _onZoomChanged(widget.controller.zoom);
  }

  void _onZoomChanged(double zoom) {
    final ratio = zoom / _zoom;
    _zoom = zoom;
    final vertical = widget.controller.verticalController;
    final horizontal = widget.controller.horizontalController;
    final v = vertical.hasClients ? vertical.offset * ratio : 0.0;
    final h = horizontal.hasClients ? horizontal.offset * ratio : 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (vertical.hasClients) vertical.jumpTo(v.clamp(0.0, vertical.position.maxScrollExtent));
      if (horizontal.hasClients) horizontal.jumpTo(h.clamp(0.0, horizontal.position.maxScrollExtent));
    });
  }

  /// Saved offsets are at 1x zoom (see the readers' `_savePosition`).
  void _restoreInitialOffsets() {
    final controller = widget.controller;
    final zoom = controller.zoom;
    if (controller.verticalController.hasClients && controller.initialVerticalOffset > 0) {
      final max = controller.verticalController.position.maxScrollExtent;
      controller.verticalController.jumpTo((controller.initialVerticalOffset * zoom).clamp(0.0, max));
    }
    if (controller.horizontalController.hasClients && controller.initialHorizontalOffset > 0) {
      final max = controller.horizontalController.position.maxScrollExtent;
      controller.horizontalController.jumpTo((controller.initialHorizontalOffset * zoom).clamp(0.0, max));
    }
  }

  @override
  void didUpdateWidget(SheetGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller
      ..removeListener(_onControllerChanged)
      ..horizontalController.removeListener(oldWidget.controller.onScrolled)
      ..verticalController.removeListener(oldWidget.controller.onScrolled);
    widget.controller
      ..addListener(_onControllerChanged)
      ..horizontalController.addListener(widget.controller.onScrolled)
      ..verticalController.addListener(widget.controller.onScrolled);
    _zoom = widget.controller.zoom;
    _mergesFor = null;
    _selection.value = null;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.horizontalController.removeListener(widget.controller.onScrolled);
    widget.controller.verticalController.removeListener(widget.controller.onScrolled);
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.controller.currentRows;
    final columnCount = widget.controller.columnCount;
    if (rows.isEmpty || columnCount == 0) {
      return _EmptySheet(message: widget.emptyMessage);
    }

    return Stack(
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([widget.controller, _selection]),
          builder: (context, _) => Column(
            children: [
              if (_selection.value case final selection?)
                _SelectionBar(
                  summary: SelectionSummary.of(rows, columnCount, selection),
                  onClear: () => _selection.value = null,
                ),
              Expanded(child: _buildTable(context)),
            ],
          ),
        ),
        Positioned(right: 12, bottom: 12, child: _ZoomControls(controller: widget.controller)),
      ],
    );
  }

  /// Table row 0 is the column-letter header and table column 0 the row
  /// numbers; the sheet's visible rows/columns follow.
  Widget _buildTable(BuildContext context) {
    final controller = widget.controller;
    final geometry = controller.geometry;
    final zoom = controller.zoom;
    final merges = _mergesOf(geometry);
    final rows = controller.currentRows;
    final selection = _selection.value;

    return TableView.builder(
      verticalDetails: ScrollableDetails.vertical(controller: controller.verticalController),
      horizontalDetails: ScrollableDetails.horizontal(controller: controller.horizontalController),
      rowCount: geometry.visibleRows.length + 1,
      columnCount: geometry.visibleColumns.length + 1,
      pinnedRowCount: geometry.frozenRowCount + 1,
      pinnedColumnCount: geometry.frozenColumnCount + 1,
      rowBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent((i == 0 ? SpreadsheetController.cellHeight : geometry.rowHeight(i - 1)) * zoom),
      ),
      columnBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent(
          (i == 0 ? SpreadsheetController.rowHeaderWidth : geometry.columnWidth(i - 1)) * zoom,
        ),
      ),
      cellBuilder: (context, vicinity) {
        final r = vicinity.row;
        final c = vicinity.column;
        if (r == 0 && c == 0) return const TableViewCell(child: _Corner());
        if (r == 0) {
          final column = geometry.visibleColumns[c - 1];
          return TableViewCell(
            child: _HeaderCell(
              label: _columnLabel(column),
              zoom: zoom,
              selected: selection == GridSelection.column(column),
              semanticsLabel: 'Column ${_columnLabel(column)}',
              onTap: () => _toggleSelection(GridSelection.column(column)),
            ),
          );
        }
        if (c == 0) {
          final row = geometry.visibleRows[r - 1];
          return TableViewCell(
            child: _HeaderCell(
              label: '${row + 1}',
              zoom: zoom,
              selected: selection == GridSelection.row(row),
              semanticsLabel: 'Row ${row + 1}',
              onTap: () => _toggleSelection(GridSelection.row(row)),
            ),
          );
        }
        final merge = merges[(r, c)];
        // A merged area shows its top-left cell.
        final row = merge?.sheetRow ?? geometry.visibleRows[r - 1];
        final column = merge?.sheetColumn ?? geometry.visibleColumns[c - 1];
        final data = row < rows.length && column < rows[row].length ? rows[row][column] : null;
        final link = controller.currentSheet?.hyperlinks[(row: row, column: column)];
        final comment = controller.currentSheet?.comments[(row: row, column: column)];
        final highlight = controller.isCurrentMatch(row, column) || controller.isGoToTarget(row, column)
            ? _CellHighlight.current
            : controller.isMatch(row, column)
                ? _CellHighlight.match
                : selection?.contains(row, column) ?? false
                    ? _CellHighlight.selected
                    : _CellHighlight.none;
        return TableViewCell(
          rowMergeStart: merge?.rowStart,
          rowMergeSpan: merge?.rowSpan,
          columnMergeStart: merge?.columnStart,
          columnMergeSpan: merge?.columnSpan,
          child: _DataCell(
            data: data,
            highlight: highlight,
            zoom: zoom,
            isLink: link != null,
            hasComment: comment != null,
            onTap: () => showCellDetail(
              context,
              address: '${_columnLabel(column)}${row + 1}',
              // A formula saved without its result has no value to show.
              value: switch (data?.value) {
                FormulaValue(cached: null) => '',
                _ => data?.text ?? '',
              },
              formula: data?.formulaText,
              comment: comment,
              link: link,
              onOpenInternalLink: controller.openInternalLink,
            ),
          ),
        );
      },
    );
  }

  /// Every table cell a merged area covers -> the merge, in table
  /// coordinates. Hidden rows/columns inside a merge are skipped; a merge
  /// that would straddle the frozen panes' edge is left unmerged (the table
  /// can't merge across it).
  static const _maxMergedCells = 200000;

  Map<(int, int), _Merge> _mergesOf(SheetGeometry geometry) {
    if (identical(_mergesFor, geometry)) return _merges;
    final merges = <(int, int), _Merge>{};
    final lastRow = widget.controller.currentRows.length - 1;
    final lastColumn = widget.controller.columnCount - 1;
    for (final range in widget.controller.currentSheet?.merges ?? const <CellRange>[]) {
      // Only the sheet's own cells (a merge may run far past its data).
      final rows = [
        for (var r = range.firstRow; r <= math.min(range.lastRow, lastRow); r++)
          if (geometry.visibleIndexOfRow(r) case final v?) v,
      ];
      final columns = [
        for (var c = range.firstColumn; c <= math.min(range.lastColumn, lastColumn); c++)
          if (geometry.visibleIndexOfColumn(c) case final v?) v,
      ];
      if (rows.isEmpty || columns.isEmpty || (rows.length == 1 && columns.length == 1)) continue;
      // Merges can't overlap in Excel; a damaged file's that do are left
      // unmerged rather than handing the table conflicting spans. A cap
      // keeps a hostile file's merges from filling memory.
      if (merges.length + rows.length * columns.length > _maxMergedCells) continue;
      var overlaps = false;
      for (var r = rows.first; r <= rows.last && !overlaps; r++) {
        for (var c = columns.first; c <= columns.last && !overlaps; c++) {
          overlaps = merges.containsKey((r + 1, c + 1));
        }
      }
      if (overlaps) continue;
      bool straddles(List<int> indices, int frozen) => indices.first < frozen && indices.last >= frozen;
      if (straddles(rows, geometry.frozenRowCount) || straddles(columns, geometry.frozenColumnCount)) continue;
      final merge = _Merge(
        rowStart: rows.first + 1,
        rowSpan: rows.last - rows.first + 1,
        columnStart: columns.first + 1,
        columnSpan: columns.last - columns.first + 1,
        sheetRow: range.firstRow,
        sheetColumn: range.firstColumn,
      );
      for (var r = rows.first; r <= rows.last; r++) {
        for (var c = columns.first; c <= columns.last; c++) {
          merges[(r + 1, c + 1)] = merge;
        }
      }
    }
    _mergesFor = geometry;
    return _merges = merges;
  }
}

class _Merge {
  const _Merge({
    required this.rowStart,
    required this.rowSpan,
    required this.columnStart,
    required this.columnSpan,
    required this.sheetRow,
    required this.sheetColumn,
  });

  final int rowStart;
  final int rowSpan;
  final int columnStart;
  final int columnSpan;

  /// The sheet cell whose value the merged area shows.
  final int sheetRow;
  final int sheetColumn;
}

/// Floating −/+ zoom pill over the grid's corner (UX-32) - kept off the app
/// bar, which has no room for two more actions on a phone.
class _ZoomControls extends StatelessWidget {
  final SpreadsheetController controller;

  const _ZoomControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 2,
      borderRadius: BorderRadius.circular(999),
      child: ListenableBuilder(listenable: controller, builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.zoom_out_rounded),
              onPressed: controller.canZoomOut ? controller.zoomOut : null,
            ),
            Text('${(controller.zoom * 100).round()}%', style: Theme.of(context).textTheme.labelMedium),
            IconButton(
              tooltip: 'Zoom in',
              icon: const Icon(Icons.zoom_in_rounded),
              onPressed: controller.canZoomIn ? controller.zoomIn : null,
            ),
          ],
        );
      }),
    );
  }
}

/// Full value of a cell, which the grid truncates (UX-32), with Copy and,
/// for a linked cell, Open link. A formula cell also shows its [formula]
/// (as Excel's formula bar does, with its own Copy), and a noted cell its
/// [comment]. Web links open outside the app (`http`,
/// `https` and `mailto` only); a link to a place in the workbook
/// (`#Sheet2!A1`) goes to [onOpenInternalLink].
Future<void> showCellDetail(
  BuildContext context, {
  required String address,
  required String value,
  String? formula,
  CellComment? comment,
  String? link,
  void Function(String location)? onOpenInternalLink,
}) {
  final external = link != null && !link.startsWith('#') ? Uri.tryParse(link) : null;
  final canOpenExternal = external != null && const {'http', 'https', 'mailto'}.contains(external.scheme);
  final internal = link != null && link.startsWith('#') && onOpenInternalLink != null ? link.substring(1) : null;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cell $address', style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.5),
              child: SingleChildScrollView(
                child: SelectableText(
                  value.isNotEmpty
                      ? value
                      : formula != null
                          ? 'No saved result: the file was saved without calculating this formula.'
                          : '(empty)',
                  style: value.isEmpty
                      ? Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                          )
                      : Theme.of(sheetContext).textTheme.bodyLarge,
                ),
              ),
            ),
            if (formula != null) ...[
              const SizedBox(height: 16),
              Text('Formula', style: Theme.of(sheetContext).textTheme.labelMedium),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      formula,
                      style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy formula',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: formula));
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                ],
              ),
            ],
            if (comment != null) ...[
              const SizedBox(height: 16),
              Text(
                comment.author == null ? 'Note' : 'Note from ${comment.author}',
                style: Theme.of(sheetContext).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              SelectableText(comment.text, style: Theme.of(sheetContext).textTheme.bodyMedium),
            ],
            if (link != null) ...[
              const SizedBox(height: 8),
              Text(link, style: Theme.of(sheetContext).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                if (canOpenExternal || internal != null)
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      if (internal != null) {
                        onOpenInternalLink!(internal);
                      } else {
                        launchUrl(external!, mode: LaunchMode.externalApplication);
                      }
                    },
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open link'),
                  ),
                FilledButton.icon(
                  onPressed: value.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: value));
                          Navigator.of(sheetContext).pop();
                        },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

String _columnLabel(int index) {
  var n = index;
  var label = '';
  do {
    label = String.fromCharCode(65 + n % 26) + label;
    n = n ~/ 26 - 1;
  } while (n >= 0);
  return label;
}

class _Corner extends StatelessWidget {
  const _Corner();

  @override
  Widget build(BuildContext context) => ColoredBox(color: Theme.of(context).colorScheme.surfaceContainer);
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final double zoom;
  final bool selected;
  final String semanticsLabel;
  final VoidCallback onTap;

  const _HeaderCell({
    required this.label,
    required this.zoom,
    required this.selected,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.surfaceContainer,
            border: Border.all(color: scheme.outlineVariant, width: 0.5),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 12 * zoom,
                  color: selected ? scheme.onPrimary : null,
                ),
          ),
        ),
      ),
    );
  }
}

/// A whole row or column of the grid, picked from its header.
class GridSelection {
  const GridSelection.row(this.index) : isRow = true;
  const GridSelection.column(this.index) : isRow = false;

  final bool isRow;
  final int index;

  bool contains(int row, int column) => isRow ? row == index : column == index;

  @override
  bool operator ==(Object other) => other is GridSelection && other.isRow == isRow && other.index == index;

  @override
  int get hashCode => Object.hash(isRow, index);
}

/// What the selection bar shows: like a spreadsheet's status bar, Sum and
/// Average cover the number cells only.
class SelectionSummary {
  const SelectionSummary({required this.label, required this.values, required this.numbers});

  factory SelectionSummary.of(List<List<SheetCell?>> rows, int columnCount, GridSelection selection) {
    final cells = selection.isRow
        ? [for (var c = 0; c < columnCount; c++) selection.index < rows.length && c < rows[selection.index].length ? rows[selection.index][c] : null]
        : [for (final row in rows) selection.index < row.length ? row[selection.index] : null];
    return SelectionSummary(
      label: selection.isRow ? 'Row ${selection.index + 1}' : 'Column ${_columnLabel(selection.index)}',
      values: [for (final cell in cells) cell?.text ?? ''],
      numbers: [for (final cell in cells) if (cell?.number case final n?) n],
    );
  }

  final String label;

  /// Every cell's shown text, in order, blanks included (what Copy copies).
  final List<String> values;
  final List<num> numbers;

  int get count => values.where((v) => v.isNotEmpty).length;
  num get sum => numbers.fold<num>(0, (a, b) => a + b);
  double? get average => numbers.isEmpty ? null : sum / numbers.length;

  /// Trailing blanks dropped, so a column doesn't copy hundreds of empty lines.
  String get copyText {
    var end = values.length;
    while (end > 0 && values[end - 1].isEmpty) {
      end--;
    }
    return values.take(end).join('\n');
  }
}

String _formatNumber(num n) {
  final rounded = n is double ? double.parse(n.toStringAsFixed(4)) : n;
  return rounded == rounded.roundToDouble() && rounded.abs() < 1e15 ? rounded.toInt().toString() : rounded.toString();
}

class _SelectionBar extends StatelessWidget {
  final SelectionSummary summary;
  final VoidCallback onClear;

  const _SelectionBar({required this.summary, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final average = summary.average;
    final details = [
      // Excel's status-bar wording, short enough for a phone.
      'Count ${summary.count}',
      if (summary.numbers.isNotEmpty) 'Sum ${_formatNumber(summary.sum)}',
      if (average != null) 'Avg ${_formatNumber(average)}',
    ].join(' · ');
    return Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: summary.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: '  $details'),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
          ),
          IconButton(
            tooltip: 'Copy ${summary.label.toLowerCase()}',
            icon: const Icon(Icons.copy_rounded, size: 20),
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            onPressed: summary.count == 0
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: summary.copyText));
                    ScaffoldMessenger.maybeOf(context)
                      ?..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text('${summary.label} copied')));
                  },
          ),
          IconButton(
            tooltip: 'Clear selection',
            icon: const Icon(Icons.close_rounded, size: 20),
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

enum _CellHighlight { none, match, current, selected }

class _DataCell extends StatelessWidget {
  final SheetCell? data;
  final _CellHighlight highlight;
  final double zoom;
  final bool isLink;
  final bool hasComment;
  final VoidCallback onTap;

  const _DataCell({
    required this.data,
    required this.highlight,
    required this.zoom,
    required this.isLink,
    required this.onTap,
    this.hasComment = false,
  });

  /// Office's default font size; the grid draws it at 13 logical px.
  static const _defaultPoints = 11.0;
  static const _defaultFontSize = 13.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = data?.style ?? CellStyle.plain;
    final background = style.fillColor == null ? null : Color(style.fillColor!);
    // Theme colours, not a hard-coded orange (UX-32): the current match
    // stands out, other matches are marked lightly.
    final fill = switch (highlight) {
      _CellHighlight.current => scheme.tertiaryContainer,
      _CellHighlight.match => scheme.secondaryContainer.withValues(alpha: 0.5),
      _CellHighlight.selected => scheme.primaryContainer,
      _CellHighlight.none => background,
    };
    final textColor = switch (highlight) {
      _CellHighlight.current => scheme.onTertiaryContainer,
      _CellHighlight.selected => scheme.onPrimaryContainer,
      _CellHighlight.match => scheme.onSurface,
      _CellHighlight.none => _ownTextColor(style, fill, scheme),
    };
    final decorations = [
      if (style.underline || isLink) TextDecoration.underline,
      if (style.strikethrough) TextDecoration.lineThrough,
    ];
    final bar = data?.dataBar;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6 * zoom, vertical: 2 * zoom),
        alignment: _alignment(style, data?.value),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: fill,
          border: cellBorder(style.borders, gridline: scheme.outlineVariant, automatic: scheme.onSurface, zoom: zoom),
        ),
        foregroundDecoration: hasComment ? _CommentMarker(color: scheme.error, size: 7 * zoom) : null,
        child: _withBar(bar, _alignment(style, data?.value), Text(
          data?.text ?? '',
          maxLines: style.wrapText ? null : 1,
          softWrap: style.wrapText,
          overflow: style.wrapText ? TextOverflow.clip : TextOverflow.ellipsis,
          textAlign: _textAlign(style, data?.value),
          style: TextStyle(
            color: textColor,
            fontSize: (style.fontSize ?? _defaultPoints) * _defaultFontSize / _defaultPoints * zoom,
            fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
            decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
          ),
        )),
      ),
    );
  }

  /// [text] over a conditional-formatting data bar, which runs from the
  /// cell's left edge (inside its padding) as a soft gradient, as Excel
  /// draws it. The text keeps its [alignment].
  static Widget _withBar(DataBar? bar, Alignment alignment, Widget text) {
    if (bar == null) return text;
    final color = Color(bar.color);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: bar.fraction,
            heightFactor: 0.8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.25)]),
                border: Border.all(color: color, width: 0.5),
              ),
            ),
          ),
        ),
        Align(alignment: alignment, child: text),
      ],
    );
  }

  /// The file's text colour where it stays readable; otherwise one chosen
  /// for the fill (or the theme surface). Links take the theme's link
  /// colour unless the file set one.
  Color _ownTextColor(CellStyle style, Color? fill, ColorScheme scheme) {
    final onFill = fill == null ? scheme.onSurface : (fill.computeLuminance() > 0.5 ? Colors.black87 : Colors.white);
    final own = style.textColor == null ? (isLink ? scheme.primary : null) : Color(style.textColor!);
    if (own == null) return onFill;
    final behind = fill ?? scheme.surface;
    final contrast = (own.computeLuminance() + 0.05) / (behind.computeLuminance() + 0.05);
    final ratio = contrast >= 1 ? contrast : 1 / contrast;
    return ratio >= 3 ? own : onFill;
  }

  /// Excel's General alignment: numbers right, booleans and errors centred,
  /// text left.
  static HorizontalAlignment _horizontal(CellStyle style, CellValue? value) {
    if (style.horizontalAlignment != HorizontalAlignment.general) return style.horizontalAlignment;
    final shown = value is FormulaValue ? value.cached : value;
    return switch (shown) {
      NumberValue() => HorizontalAlignment.right,
      BoolValue() || ErrorValue() => HorizontalAlignment.center,
      _ => HorizontalAlignment.left,
    };
  }

  static Alignment _alignment(CellStyle style, CellValue? value) {
    final x = switch (_horizontal(style, value)) {
      HorizontalAlignment.right => 1.0,
      HorizontalAlignment.center || HorizontalAlignment.centerContinuous => 0.0,
      _ => -1.0,
    };
    // Bottom (Excel's default) is drawn centred: rows here are taller than
    // Excel's for touch, and bottom-aligned text would look dropped.
    final y = switch (style.verticalAlignment) {
      VerticalAlignment.top => -1.0,
      _ => 0.0,
    };
    return Alignment(x, y);
  }

  static TextAlign _textAlign(CellStyle style, CellValue? value) => switch (_horizontal(style, value)) {
        HorizontalAlignment.right => TextAlign.right,
        HorizontalAlignment.center || HorizontalAlignment.centerContinuous => TextAlign.center,
        HorizontalAlignment.justify || HorizontalAlignment.distributed => TextAlign.justify,
        _ => TextAlign.left,
      };
}

class _EmptySheet extends StatelessWidget {
  const _EmptySheet({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        Icon(Icons.grid_off_rounded, size: 56, color: colors.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colors.onSurface),
        ),
      ],
    );
  }
}

/// Excel's note marker: a small triangle in a cell's top-right corner.
class _CommentMarker extends Decoration {
  const _CommentMarker({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _CommentMarkerPainter(this);
}

class _CommentMarkerPainter extends BoxPainter {
  _CommentMarkerPainter(this.marker);

  final _CommentMarker marker;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final right = offset.dx + size.width;
    final top = offset.dy;
    final path = Path()
      ..moveTo(right - marker.size, top)
      ..lineTo(right, top)
      ..lineTo(right, top + marker.size)
      ..close();
    canvas.drawPath(path, Paint()..color = marker.color);
  }
}

/// Asks for a cell or sheet and goes there with
/// [SpreadsheetController.goTo]: `D120`, `Sheet2!B3`, or a sheet's name
/// (the sheets are offered as chips). Stays open with a message when
/// there's no such place.
Future<void> showGoToDialog(BuildContext context, SpreadsheetController controller) {
  return showDialog<void>(context: context, builder: (_) => _GoToDialog(controller: controller));
}

class _GoToDialog extends StatefulWidget {
  const _GoToDialog({required this.controller});

  final SpreadsheetController controller;

  @override
  State<_GoToDialog> createState() => _GoToDialogState();
}

class _GoToDialogState extends State<_GoToDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _go(String reference) {
    if (widget.controller.goTo(reference)) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = 'No cell or sheet called "${reference.trim()}"');
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.controller.sheetNames;
    return AlertDialog(
      title: const Text('Go to'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _field,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              labelText: 'Cell',
              hintText: names.length > 1 ? 'D120 or ${names[1]}!B3' : 'D120',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: _go,
          ),
          if (names.length > 1) ...[
            const SizedBox(height: 16),
            Text('Sheets', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < names.length; i++)
                  ChoiceChip(
                    label: Text(names[i]),
                    selected: i == widget.controller.activeSheetIndex,
                    onSelected: (_) {
                      widget.controller.switchSheet(i);
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => _go(_field.text), child: const Text('Go')),
      ],
    );
  }
}
