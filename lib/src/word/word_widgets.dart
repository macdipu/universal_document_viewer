import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../engines/word/word_model.dart';
import 'word_document_layout.dart';
import 'word_paragraph_styler.dart';
import 'word_search_controller.dart';

/// What every block widget of a Word document needs, provided once above
/// them: the layout (paragraph numbers), search highlights, and what tapping
/// a link or a note mark does.
class WordScope extends InheritedWidget {
  const WordScope({
    super.key,
    required this.layout,
    required this.search,
    required this.onLink,
    required this.onNote,
    required this.anchors,
    required super.child,
  });

  /// Points -> logical pixels.
  static const double scale = wordScale;

  final WordDocumentLayout layout;
  final WordSearchController search;
  final void Function(WordLink link) onLink;
  final void Function(WordNoteReference note) onNote;

  /// Paragraph number -> the context of its widget while it's built, so a
  /// jump can scroll it into view.
  final Map<int, BuildContext> anchors;

  static WordScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WordScope>()!;

  @override
  bool updateShouldNotify(WordScope oldWidget) => layout != oldWidget.layout || search != oldWidget.search;
}

/// Set around a page in the paged view: the page's number (for `PAGE`
/// fields) and the page count (for `NUMPAGES`).
class WordPageInfo extends InheritedWidget {
  const WordPageInfo({super.key, required this.number, required this.count, required super.child});

  final int number;
  final int count;

  static WordPageInfo? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<WordPageInfo>();

  @override
  bool updateShouldNotify(WordPageInfo oldWidget) => number != oldWidget.number || count != oldWidget.count;
}

/// The styler for the current theme, document and page.
WordParagraphStyler stylerOf(BuildContext context) {
  final page = WordPageInfo.maybeOf(context);
  return WordParagraphStyler(
    scheme: Theme.of(context).colorScheme,
    linkColor: WordScope.of(context).layout.document.linkColor,
    pageNumber: page?.number,
    pageCount: page?.count,
  );
}

/// One block: a paragraph, a table, or a section break.
class WordBlockView extends StatelessWidget {
  const WordBlockView(this.block, {super.key});

  final WordBlock block;

  @override
  Widget build(BuildContext context) => switch (block) {
        final WordParagraph paragraph => WordParagraphView(paragraph),
        final WordTable table => WordTableView(table),
        WordSectionBreak() => WordPageInfo.maybeOf(context) == null ? const Divider(height: 24) : const SizedBox.shrink(),
      };
}

// --- Paragraphs ----------------------------------------------------------------

class WordParagraphView extends StatefulWidget {
  /// [number] and [textOffset] are for a piece of a paragraph split across
  /// pages: the whole paragraph's number, and where this piece starts in
  /// its text.
  const WordParagraphView(this.paragraph, {super.key, this.number, this.textOffset = 0});

  final WordParagraph paragraph;
  final int? number;
  final int textOffset;

  @override
  State<WordParagraphView> createState() => _WordParagraphViewState();
}

class _WordParagraphViewState extends State<WordParagraphView> {
  /// Owned here and disposed: one per link in the paragraph.
  final _recognizers = <TapGestureRecognizer>[];
  int? _number;
  WordScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(WordParagraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paragraph != widget.paragraph || oldWidget.number != widget.number) _register();
  }

  void _register() {
    _unregister();
    _scope = WordScope.of(context);
    _number = widget.number ?? _scope!.layout.numberOf(widget.paragraph);
    // A later piece of a split paragraph doesn't replace the first as the
    // jump target.
    if (_number != null && (widget.textOffset == 0 || !_scope!.anchors.containsKey(_number))) {
      _scope!.anchors[_number!] = context;
    }
  }

  void _unregister() {
    if (_number != null && identical(_scope?.anchors[_number!], context)) _scope!.anchors.remove(_number);
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _unregister();
    _disposeRecognizers();
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    final scope = WordScope.of(context);
    final styler = stylerOf(context);
    final paged = WordPageInfo.maybeOf(context) != null;
    return ListenableBuilder(
      listenable: scope.search,
      builder: (context, _) {
        _disposeRecognizers();
        return LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
          return _buildParagraph(context, scope, styler, ParagraphGeometry(widget.paragraph, width), paged);
        });
      },
    );
  }

  Widget _buildParagraph(
    BuildContext context,
    WordScope scope,
    WordParagraphStyler styler,
    ParagraphGeometry geometry,
    bool paged,
  ) {
    final paragraph = widget.paragraph;
    final format = paragraph.format;
    final fill = format.fill == null ? null : Color(format.fill!);
    final highlights = _number == null ? const <WordHighlight>[] : scope.search.highlightsOf(_number!);
    final spans = styler.spans(
      paragraph,
      highlights: highlights,
      textOffset: widget.textOffset,
      tap: _tap,
      onLink: scope.onLink,
      onNote: scope.onNote,
      imageBuilder: (image) => WordImageView(image, maxWidth: geometry.textWidth),
      imageWidth: geometry.textWidth,
    );
    final text = Text.rich(
      spans.root,
      textAlign: WordParagraphStyler.textAlignOf(format),
      textDirection: format.rightToLeft ? TextDirection.rtl : null,
    );

    Widget body = text;
    final marker = paragraph.marker;
    if (marker != null && WordParagraphStyler.markerInColumn(paragraph)) {
      final lineHeight = WordParagraphStyler.lineHeightOf(format, WordParagraphStyler.firstSizeOf(paragraph));
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: geometry.markerWidth,
            child: Text(
              marker.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: styler.textStyle(marker.format, fill, link: false).copyWith(height: lineHeight),
            ),
          ),
          Expanded(child: text),
        ],
      );
    }

    Widget result = Padding(
      padding: EdgeInsetsDirectional.only(start: geometry.start, end: geometry.end),
      child: body,
    );
    if (geometry.decorated) {
      final scheme = Theme.of(context).colorScheme;
      BorderSide side(BorderLine? line) => line == null || line.width == 0
          ? BorderSide.none
          : BorderSide(
              // Under 1 px, a hairline (see the table cells).
              width: line.width * wordScale < 1 ? 0 : line.width * wordScale,
              color: line.color == null ? scheme.onSurface : Color(line.color!),
            );
      result = DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          border: Border(
            top: side(format.borderTop),
            bottom: side(format.borderBottom),
            left: side(format.borderLeft),
            right: side(format.borderRight),
          ),
        ),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4), child: result),
      );
    }
    result = Padding(
      padding: EdgeInsets.only(top: geometry.spaceBefore, bottom: geometry.spaceAfter),
      child: result,
    );
    if (paragraph.outlineLevel != null) result = Semantics(header: true, child: result);
    // Continuous view: a page break shows as a rule. Pages break for real.
    if (!paged && paragraph.inlines.any((i) => i is WordBreak && i.kind == BreakKind.page)) {
      result = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [result, const Divider(height: 24)]);
    }
    return result;
  }
}

// --- Images --------------------------------------------------------------------

/// An image at its size in the document, shrunk to fit; a placeholder
/// (with its alt text) when it can't be shown.
class WordImageView extends StatelessWidget {
  const WordImageView(this.image, {super.key, required this.maxWidth});

  final WordImage image;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final bytes = WordScope.of(context).layout.document.images[image.part];
    final size = WordParagraphStyler.imageSize(image, maxWidth);
    final placeholder = Container(
      width: size.width,
      height: size.height,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.image_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
    return Semantics(
      image: true,
      label: image.description,
      child: bytes == null
          ? placeholder
          : Image.memory(
              bytes,
              width: size.width,
              height: size.height,
              fit: BoxFit.contain,
              cacheWidth: (size.width * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

// --- Tables ----------------------------------------------------------------------

/// A table on its grid: column widths from the document, shrunk to fit the
/// screen (with a minimum per column, scrolling sideways beyond that);
/// spanned and vertically merged cells laid out over the columns and rows
/// they cover.
class WordTableView extends StatelessWidget {
  const WordTableView(this.table, {super.key});

  final WordTable table;

  static const double _minColumnWidth = 48;

  /// Column widths in logical pixels for [available] width: the
  /// document's, shrunk to fit with a minimum per column.
  static List<double> columnWidthsFor(WordTable table, double available) {
    final columnCount = columnCountOf(table);
    var widths = [
      for (var c = 0; c < columnCount; c++)
        (c < table.columnWidths.length && table.columnWidths[c] > 0 ? table.columnWidths[c] : 72) * wordScale,
    ];
    final natural = widths.fold<double>(0, (a, b) => a + b);
    if (natural > available) {
      final factor = available / natural;
      widths = [for (final w in widths) math.max(_minColumnWidth, w * factor)];
    }
    return widths;
  }

  /// Horizontal padding inside a cell.
  static const double cellPaddingX = 7;
  static const double cellPaddingY = 2;

  /// Space above and below a table.
  static const double tableMarginY = 6;

  @override
  Widget build(BuildContext context) {
    final columnCount = columnCountOf(table);
    if (columnCount == 0) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
      final widths = columnWidthsFor(table, available);
      final total = widths.fold<double>(0, (a, b) => a + b);
      final cells = <Widget>[];
      for (var r = 0; r < table.rows.length; r++) {
        var column = 0;
        for (final cell in table.rows[r].cells) {
          if (!cell.covered && column < columnCount) {
            final span = math.min(cell.columnSpan, columnCount - column);
            cells.add(_TableCellSlot(
              row: r,
              column: column,
              rowSpan: math.min(cell.rowSpan, table.rows.length - r),
              columnSpan: span,
              child: _WordTableCellView(
                cell,
                top: r == 0,
                left: column == 0,
                bottom: r + cell.rowSpan >= table.rows.length,
                right: column + span >= columnCount,
              ),
            ));
          }
          column += cell.columnSpan;
        }
      }
      Widget grid = _TableGrid(
        columnWidths: widths,
        rowCount: table.rows.length,
        minRowHeights: [for (final row in table.rows) (row.height ?? 0) * wordScale],
        children: cells,
      );
      if (total > available) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: WordTableView.tableMarginY),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: grid),
        );
      }
      grid = Align(
        alignment: switch (table.alignment) {
          ParagraphAlignment.center => Alignment.center,
          ParagraphAlignment.right => AlignmentDirectional.centerEnd,
          _ => AlignmentDirectional.centerStart,
        },
        child: grid,
      );
      return Padding(padding: const EdgeInsets.symmetric(vertical: WordTableView.tableMarginY), child: grid);
    });
  }

  static int columnCountOf(WordTable table) {
    var widest = table.columnWidths.length;
    for (final row in table.rows) {
      final count = row.cells.fold<int>(0, (a, cell) => a + cell.columnSpan);
      if (count > widest) widest = count;
    }
    return widest;
  }
}

class _WordTableCellView extends StatelessWidget {
  const _WordTableCellView(this.cell, {required this.top, required this.left, required this.bottom, required this.right});

  final WordTableCell cell;

  /// Which sides are the table's outer edge. Every cell draws its top and
  /// left borders; only cells on the outer edge also draw bottom and right,
  /// so a border between two cells is drawn once.
  final bool top;
  final bool left;
  final bool bottom;
  final bool right;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    BorderSide side(BorderLine? line, bool draw) {
      if (!draw || line == null || line.width == 0) return BorderSide.none;
      final width = line.width * wordScale;
      return BorderSide(
        // Under 1 px, a hairline: always one device pixel, even on a page
        // scaled down to fit the screen (a 0.3 px line would vanish).
        width: width < 1 ? 0 : width,
        color: line.color == null ? scheme.outline : Color(line.color!),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: cell.fill == null ? null : Color(cell.fill!),
        border: Border(
          top: side(cell.borders.top, true),
          left: side(cell.borders.left, true),
          bottom: side(cell.borders.bottom, bottom),
          right: side(cell.borders.right, right),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: WordTableView.cellPaddingX, vertical: WordTableView.cellPaddingY),
      alignment: switch (cell.verticalAlignment) {
        CellVerticalAlignment.top => AlignmentDirectional.topStart,
        CellVerticalAlignment.center => AlignmentDirectional.centerStart,
        CellVerticalAlignment.bottom => AlignmentDirectional.bottomStart,
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final block in cell.blocks) WordBlockView(block)],
      ),
    );
  }
}

/// Where a cell sits on the table grid.
class _TableCellSlot extends ParentDataWidget<_TableCellData> {
  const _TableCellSlot({
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
    required super.child,
  });

  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _TableCellData;
    if (data.row != row || data.column != column || data.rowSpan != rowSpan || data.columnSpan != columnSpan) {
      data
        ..row = row
        ..column = column
        ..rowSpan = rowSpan
        ..columnSpan = columnSpan;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _TableGrid;
}

class _TableCellData extends ContainerBoxParentData<RenderBox> {
  int row = 0;
  int column = 0;
  int rowSpan = 1;
  int columnSpan = 1;
}

class _TableGrid extends MultiChildRenderObjectWidget {
  const _TableGrid({required this.columnWidths, required this.rowCount, required this.minRowHeights, super.children});

  final List<double> columnWidths;
  final int rowCount;
  final List<double> minRowHeights;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTableGrid(columnWidths, rowCount, minRowHeights);

  @override
  void updateRenderObject(BuildContext context, _RenderTableGrid renderObject) {
    renderObject
      ..columnWidths = columnWidths
      ..rowCount = rowCount
      ..minRowHeights = minRowHeights;
  }
}

/// Lays cells out on fixed columns: each row is as tall as its tallest
/// single-row cell (and its minimum height); a cell spanning rows adds any
/// height it still needs to the last row it covers. Then every cell is
/// stretched to its full area, so fills and borders line up.
class _RenderTableGrid extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _TableCellData>, RenderBoxContainerDefaultsMixin<RenderBox, _TableCellData> {
  _RenderTableGrid(this._columnWidths, this._rowCount, this._minRowHeights);

  List<double> _columnWidths;
  set columnWidths(List<double> value) {
    _columnWidths = value;
    markNeedsLayout();
  }

  int _rowCount;
  set rowCount(int value) {
    _rowCount = value;
    markNeedsLayout();
  }

  List<double> _minRowHeights;
  set minRowHeights(List<double> value) {
    _minRowHeights = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TableCellData) child.parentData = _TableCellData();
  }

  double _spanWidth(_TableCellData data) {
    var width = 0.0;
    for (var c = data.column; c < data.column + data.columnSpan && c < _columnWidths.length; c++) {
      width += _columnWidths[c];
    }
    return width;
  }

  List<double> _rowHeights(double Function(RenderBox child, double width) measure) {
    final heights = [for (var r = 0; r < _rowCount; r++) r < _minRowHeights.length ? _minRowHeights[r] : 0.0];
    final spanning = <(RenderBox, _TableCellData, double)>[];
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _TableCellData;
      final height = measure(child, _spanWidth(data));
      if (data.rowSpan <= 1) {
        heights[data.row] = math.max(heights[data.row], height);
      } else {
        spanning.add((child, data, height));
      }
      child = data.nextSibling;
    }
    for (final (_, data, height) in spanning) {
      final last = math.min(data.row + data.rowSpan, _rowCount) - 1;
      var covered = 0.0;
      for (var r = data.row; r <= last; r++) {
        covered += heights[r];
      }
      if (height > covered) heights[last] += height - covered;
    }
    return heights;
  }

  @override
  void performLayout() {
    final heights = _rowHeights((child, width) {
      child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      return child.size.height;
    });
    final rowTops = [0.0];
    for (final h in heights) {
      rowTops.add(rowTops.last + h);
    }
    final columnLefts = [0.0];
    for (final w in _columnWidths) {
      columnLefts.add(columnLefts.last + w);
    }
    var child = firstChild;
    while (child != null) {
      final data = child.parentData! as _TableCellData;
      final last = math.min(data.row + data.rowSpan, _rowCount);
      final height = rowTops[last] - rowTops[data.row];
      child.layout(BoxConstraints.tightFor(width: _spanWidth(data), height: height));
      data.offset = Offset(columnLefts[math.min(data.column, _columnWidths.length)], rowTops[data.row]);
      child = data.nextSibling;
    }
    size = constraints.constrain(Size(columnLefts.last, rowTops.last));
  }

  double get _width => _columnWidths.fold(0.0, (a, b) => a + b);

  @override
  double computeMinIntrinsicWidth(double height) => _width;

  @override
  double computeMaxIntrinsicWidth(double height) => _width;

  @override
  double computeMinIntrinsicHeight(double width) =>
      _rowHeights((child, w) => child.getMinIntrinsicHeight(w)).fold(0.0, (a, b) => a + b);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _rowHeights((child, w) => child.getMaxIntrinsicHeight(w)).fold(0.0, (a, b) => a + b);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
