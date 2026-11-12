import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/document_viewer_strings.dart';
import '../common/document_viewer_theme.dart';
import '../engines/spreadsheet/number_format.dart';
import '../engines/spreadsheet/workbook.dart';
import 'cell_border.dart';
import 'grid_selection.dart';
import 'sheet_density.dart';
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
class SpreadsheetView extends StatefulWidget {
  /// Shows [controller]'s sheet on screen.
  const SpreadsheetView({
    super.key,
    required this.controller,
    this.emptyMessage,
    this.selectionColor,
    this.showScrollbars = true,
  });

  /// The colour of the selection (outline, tint, highlighted headers,
  /// focus ring). Defaults to the theme's primary colour.
  final Color? selectionColor;

  /// Whether the grid shows scrollbars: draggable ones in their own gutter
  /// beside the grid on a desktop, thumbs that fade out on a phone.
  final bool showScrollbars;

  /// The workbook to show.
  final SpreadsheetController controller;

  /// Shown instead of the grid for a sheet with no cells. Defaults to
  /// [DocumentViewerStrings.emptySheet].
  final String? emptyMessage;

  @override
  State<SpreadsheetView> createState() => _SpreadsheetViewState();
}

class _SpreadsheetViewState extends State<SpreadsheetView> {
  final _focus = FocusNode(debugLabel: 'SpreadsheetView grid');

  /// Whether the grid has focus and the user is on the keyboard (not a
  /// pointer or touch): the grid then gets a visible ring.
  bool _showFocusRing = false;

  void _onHighlightModeChanged(FocusHighlightMode mode) => _onFocusChanged();

  /// Whether the last input was a key: a desktop is always in "traditional"
  /// focus mode, so without this the ring would frame the grid after every
  /// mouse click.
  bool _keyboardUsed = false;

  void _setKeyboardUsed(bool used) {
    if (used == _keyboardUsed) return;
    _keyboardUsed = used;
    _onFocusChanged();
  }

  void _onFocusChanged() {
    final ring =
        _keyboardUsed && _focus.hasFocus && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (ring != _showFocusRing && mounted) setState(() => _showFocusRing = ring);
  }

  /// The selection as it was when the pointer last went down: a tap on the
  /// already active cell opens its details instead of reselecting it.
  GridSelection? _selectionBeforeDown;

  /// Whether the mouse already selected on this press (so its tap doesn't
  /// select again and undo a Shift+click).
  bool _pointerSelected = false;
  bool _dragging = false;

  /// Whether a finger is extending the selection after a long press (the
  /// same finger drags on). Scrolling is off only while it is down.
  bool _touchDragging = false;

  /// Whether a finger is on a selection handle (down, or dragging it).
  /// Scrolling is off while it is.
  bool _handleActive = false;

  /// Which corner a handle drag moves: the start (top-left) or the end.
  bool _draggingStartHandle = false;

  /// The sheet column a finger is resizing by touch (the grip of a selected
  /// column, or a long press on a header's edge): draws the guide line and
  /// keeps the grid still.
  int? _resizingColumn;
  double _resizeStartWidth = 0;
  double _resizeStartX = 0;

  void _setResizing(int? column) {
    if (column == _resizingColumn) return;
    setState(() => _resizingColumn = column);
  }

  /// A finger went down on [column]'s resize zone (global [position]).
  void _beginResize(int column, Offset position) {
    final controller = widget.controller;
    final visible = controller.geometry.visibleIndexOfColumn(column);
    if (visible == null) return;
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    _resizeStartX = box == null ? position.dx : box.globalToLocal(position).dx;
    _resizeStartWidth = controller.geometry.columnWidth(visible);
    _setResizing(column);
  }

  void _resizeTo(int column, Offset position) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final dx = box.globalToLocal(position).dx - _resizeStartX;
    widget.controller.setColumnWidth(column, _resizeStartWidth + dx / widget.controller.zoom);
  }

  /// Fits [column] to its text, measured in the style the cells draw with.
  void _fitColumn(BuildContext context, int column) =>
      widget.controller.autoFitColumn(column, baseStyle: DefaultTextStyle.of(context).style);

  /// A selected column picked by touch shows a grip on its right edge.
  bool _showColumnGrip(GridSelection? selection) =>
      selection != null &&
      selection.isColumn &&
      _lastPointerKind != null &&
      !_isMouseLike(_lastPointerKind!) &&
      !_keyboardUsed;

  /// Where the right edge of [column] is on the grid, or null when hidden.
  double? _columnRight(int column) {
    final controller = widget.controller;
    final grid = controller.geometry;
    final c = grid.visibleIndexOfColumn(column);
    if (c == null) return null;
    final h = controller.horizontalController;
    return (controller.metrics.rowHeaderWidth + grid.columnStart(c + 1)) * controller.zoom -
        (c < grid.frozenColumnCount || !h.hasClients ? 0 : h.offset);
  }

  /// The resize grip of the selected [column], and the guide line while one
  /// is being resized.
  List<Widget> _columnResizeOverlay(BuildContext context, int column, Color accent) {
    final controller = widget.controller;
    final strings = DocumentViewerStrings.of(context);
    final header = controller.metrics.headerHeight * controller.zoom;
    final minX = controller.metrics.rowHeaderWidth * controller.zoom;
    final right = _columnRight(column);
    final resizing = _resizingColumn == null ? null : _columnRight(_resizingColumn!);
    return [
      if (right != null && right >= minX && right <= _viewport.width + 24)
        Positioned(
          left: right - _ColumnGrip.hitWidth / 2,
          top: 0,
          width: _ColumnGrip.hitWidth,
          height: header,
          child: _ColumnGrip(
            accent: accent,
            semanticsLabel: strings.resizeColumn,
            onGrab: (global) => _beginResize(column, global),
            onDrag: (global) => _resizeTo(column, global),
            onEnd: () => _setResizing(null),
            onFit: () => _fitColumn(context, column),
          ),
        ),
      if (resizing != null)
        Positioned(
          left: resizing - 1,
          top: 0,
          bottom: 0,
          width: 2,
          child: IgnorePointer(child: ColoredBox(color: accent.withValues(alpha: 0.85))),
        ),
    ];
  }

  /// Where the finger grabbed a handle, relative to the handle's corner, so
  /// the selection does not jump when it is picked up.
  Offset _grabOffset = Offset.zero;

  void _setTouchDragging(bool value) {
    if (value == _touchDragging) return;
    setState(() => _touchDragging = value);
  }

  void _setHandleActive(bool value) {
    if (value == _handleActive) return;
    setState(() => _handleActive = value);
  }

  /// A cell or range picked by touch shows handles on its corners (drag one
  /// to grow or shrink it), without a long press first.
  bool _showHandles(GridSelection? selection) =>
      selection != null &&
      (selection.isSingleCell || selection.kind == GridSelectionKind.range) &&
      _lastPointerKind != null &&
      !_isMouseLike(_lastPointerKind!) &&
      !_keyboardUsed;

  final _gridKey = GlobalKey();
  Size _viewport = Size.zero;

  /// The last place a finger extended the selection, for edge auto-scroll.
  Offset? _lastTouch;
  Timer? _autoScroll;

  /// Fingers on the grid, for pinch zoom.
  final _touches = <int, Offset>{};
  double? _pinchStartDistance;
  double _pinchStartZoom = 1;

  bool get _pinching => _pinchStartDistance != null;

  /// The kind of the last pointer that went down (a mouse long press is
  /// not touch range selection).
  PointerDeviceKind? _lastPointerKind;

  bool get _lockScroll => _pinching || _touchDragging || _handleActive || _resizingColumn != null;

  SpreadsheetController get _controller => widget.controller;

  /// The right-click menu of a cell: copy and details. A cell outside the
  /// selection becomes the selection first, as in spreadsheets.
  Future<void> _showCellMenu(
    BuildContext context,
    Offset position,
    int row,
    int column,
    VoidCallback openDetails,
  ) async {
    final controller = widget.controller;
    if (!(controller.selection.value?.contains(row, column) ?? false)) {
      controller.select(GridSelection.cell(row, column));
    }
    _focus.requestFocus();
    final strings = DocumentViewerStrings.of(context);
    final selection = controller.selection.value!;
    final address = selection.address(rowCount: controller.currentRows.length, columnCount: controller.columnCount);
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'copy', child: Text(strings.copy)),
        PopupMenuItem(value: 'address', child: Text(strings.copyAddress)),
        PopupMenuItem(value: 'details', child: Text(strings.cellDetails)),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'copy':
        await _copySelection();
      case 'address':
        // ignore: use_build_context_synchronously
        await _copyText(this.context, address, address);
      case 'details':
        openDetails();
    }
  }

  /// A header tap selects its row or column; tapping it again clears.
  void _toggleSelection(GridSelection selection) {
    _focus.requestFocus();
    _controller.select(_controller.selection.value == selection ? null : selection);
  }

  late double _zoom;

  /// The summary of the selection last computed, for the rows and
  /// selection it was computed from (so scrolling and searching don't redo
  /// it).
  SelectionSummary? _summary;
  GridSelection? _summaryFor;
  List<List<SheetCell?>>? _summaryRows;

  /// Merged areas in table coordinates, for the geometry they were built
  /// from.
  SheetGeometry? _mergesFor;
  Map<(int, int), _Merge> _merges = const {};

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreInitialOffsets());
    widget.controller.horizontalController.addListener(widget.controller.onScrolled);
    widget.controller.verticalController.addListener(widget.controller.onScrolled);
    // Read now, not lazily: the first read used to happen inside the zoom
    // handler, after the change, so the first zoom wasn't anchored.
    _zoom = widget.controller.zoom;
    widget.controller.addListener(_onControllerChanged);
    _adoptDensity();
  }

  /// A desktop starts compact (it has a mouse); a phone or tablet starts
  /// touch. After that the input in use decides, on every platform: a mouse
  /// or trackpad moving over the grid (a tablet with a mouse attached, an
  /// iPad with a trackpad) means compact; a finger means touch. Silent: it
  /// runs while the view is being built.
  void _adoptDensity() =>
      widget.controller.setAutoDensity(_isDesktop ? SheetDensity.compact : SheetDensity.touch, notify: false);

  static bool get _isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
    _ => false,
  };

  /// A mouse or trackpad moving over the grid means compact rows (switched
  /// on hover, before any click); a finger means touch rows (switched when
  /// it lifts, so the cells never move under it).
  void _onPointerHover(PointerHoverEvent event) {
    if (_isMouseLike(event.kind)) widget.controller.setAutoDensity(SheetDensity.compact);
  }

  static bool _isMouseLike(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

  /// Keeps the same cells in view across a zoom change: offsets scale by
  /// the zoom ratio once the resized grid has laid out.
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
  void didUpdateWidget(SpreadsheetView oldWidget) {
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
    _adoptDensity();
    _mergesFor = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreInitialOffsets();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.horizontalController.removeListener(widget.controller.onScrolled);
    widget.controller.verticalController.removeListener(widget.controller.onScrolled);
    _autoScroll?.cancel();
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A go-to asked for before the grid was laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.applyPending();
    });
    final rows = widget.controller.currentRows;
    final columnCount = widget.controller.columnCount;
    if (rows.isEmpty || columnCount == 0) {
      return _EmptySheet(message: widget.emptyMessage ?? DocumentViewerStrings.of(context).emptySheet);
    }

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          widget.controller,
          widget.controller.selection,
          widget.controller.verticalController,
          widget.controller.horizontalController,
        ]),
        builder: (context, _) {
          final selection = widget.controller.selection.value;
          final accent = widget.selectionColor ?? Theme.of(context).colorScheme.primary;
          return Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // The scrollbar gutter is not part of the grid.
                    _viewport = Size(constraints.maxWidth - _gutter, constraints.maxHeight - _gutter);
                    return DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(border: _showFocusRing ? Border.all(color: accent, width: 2) : null),
                      child: Listener(
                        key: _gridKey,
                        onPointerDown: _onPointerDown,
                        onPointerHover: _onPointerHover,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerEnd,
                        onPointerCancel: _onPointerEnd,
                        child: Stack(
                          children: [
                            Positioned.fill(child: _gridArea(context, accent)),
                            if (_showHandles(selection)) ..._handles(context, selection!, accent),
                            if (_showColumnGrip(selection))
                              ..._columnResizeOverlay(context, selection!.index, accent)
                            else if (_resizingColumn != null)
                              ..._columnResizeOverlay(context, _resizingColumn!, accent),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              // Below the grid, like a spreadsheet's status bar: showing it
              // never moves the cells under the pointer.
              if (selection != null)
                _SelectionBar(
                  accent: accent,
                  summary: _summaryOf(context, rows, columnCount, selection),
                  onClear: widget.controller.clearSelection,
                  onCopy: _copySelection,
                  columnWidthActions: selection.isColumn
                      ? (
                          fit: () => _fitColumn(context, selection.index),
                          reset: widget.controller.hasColumnWidthOverride(selection.index)
                              ? () => widget.controller.setColumnWidth(selection.index, null)
                              : null,
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }

  SelectionSummary _summaryOf(
    BuildContext context,
    List<List<SheetCell?>> rows,
    int columnCount,
    GridSelection selection,
  ) {
    if (_summary != null && _summaryFor == selection && identical(_summaryRows, rows)) return _summary!;
    _summaryFor = selection;
    _summaryRows = rows;
    return _summary = SelectionSummary.of(rows, columnCount, selection, DocumentViewerStrings.of(context));
  }

  /// The sheet cell under [position] (local to the grid), a merged area
  /// counting as its top-left cell; null over a header or past the data.
  (int, int)? _cellAt(Offset position) {
    final controller = widget.controller;
    final grid = controller.geometry;
    final zoom = controller.zoom;
    final x = position.dx / zoom - controller.metrics.rowHeaderWidth;
    final y = position.dy / zoom - controller.metrics.headerHeight;
    if (x < 0 || y < 0 || grid.visibleRows.isEmpty || grid.visibleColumns.isEmpty) return null;
    final horizontal = controller.horizontalController;
    final vertical = controller.verticalController;
    // Past the frozen panes the grid is scrolled; inside them it is not.
    final contentX = x < grid.frozenWidth ? x : x + (horizontal.hasClients ? horizontal.offset : 0) / zoom;
    final contentY = y < grid.frozenHeight ? y : y + (vertical.hasClients ? vertical.offset : 0) / zoom;
    if (contentX >= grid.contentWidth || contentY >= grid.contentHeight) return null;
    final r = grid.visibleRowAtY(contentY);
    final c = grid.visibleColumnAtX(contentX);
    final merge = _mergesOf(grid)[(r + 1, c + 1)];
    return (merge?.sheetRow ?? grid.visibleRows[r], merge?.sheetColumn ?? grid.visibleColumns[c]);
  }

  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  /// [event]'s position on the grid now. Not `event.localPosition`: a move
  /// reuses the transform from when the pointer went down, which is stale
  /// once the layout around the grid changes.
  Offset _local(PointerEvent event) {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? event.localPosition : box.globalToLocal(event.position);
  }

  /// Copies the selection as TSV, or says it is too big.
  Future<void> _copySelection() async {
    final selection = widget.controller.selection.value;
    if (selection == null) return;
    final rows = widget.controller.currentRows;
    final columns = widget.controller.columnCount;
    final text = widget.controller.selectedText();
    final strings = DocumentViewerStrings.of(context);
    if (text == null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.tooLargeToCopy)));
      return;
    }
    final what = switch (selection.kind) {
      GridSelectionKind.row => strings.row(selection.index + 1),
      GridSelectionKind.column => strings.column(columnLabel(selection.index)),
      _ => selection.address(rowCount: rows.length, columnCount: columns),
    };
    await _copyText(context, text, what);
  }

  void _onPointerDown(PointerDownEvent event) {
    final controller = widget.controller;
    _setKeyboardUsed(false);
    _lastPointerKind = event.kind;
    if (event.kind == PointerDeviceKind.touch) {
      _touches[event.pointer] = _local(event);
      if (_touches.length == 2) {
        // A second finger: pinch zoom, never a selection.
        final points = _touches.values.toList();
        _pinchStartDistance = (points[0] - points[1]).distance;
        _pinchStartZoom = controller.zoom;
        _touchDragging = false;
        setState(() {});
        return;
      }
    }
    _selectionBeforeDown = controller.selection.value;
    _pointerSelected = false;
    _dragging = false;
    // A mouse selects on press, so it can drag; touch selects on tap, so
    // a swipe still scrolls.
    if (event.kind != PointerDeviceKind.mouse || event.buttons != kPrimaryMouseButton) return;
    final cell = _cellAt(_local(event));
    if (cell == null) return;
    _focus.requestFocus();
    final (row, column) = cell;
    final current = controller.selection.value;
    final extend = _shift && current != null && (current.isSingleCell || current.kind == GridSelectionKind.range);
    controller.select(extend ? current.extendedTo(row, column) : GridSelection.cell(row, column));
    _pointerSelected = true;
    _dragging = true;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      if (_touches.containsKey(event.pointer)) _touches[event.pointer] = _local(event);
      if (_pinching && _touches.length >= 2) {
        final points = _touches.values.toList();
        final distance = (points[0] - points[1]).distance;
        if (_pinchStartDistance! > 0) widget.controller.setZoom(_pinchStartZoom * distance / _pinchStartDistance!);
        return;
      }
      if (_touchDragging) _extendTouch(_local(event));
      return;
    }
    if (!_dragging || event.kind != PointerDeviceKind.mouse) return;
    final cell = _cellAt(_local(event));
    final current = widget.controller.selection.value;
    if (cell == null || current == null) return;
    final (row, column) = cell;
    final next = current.extendedTo(row, column);
    if (next != current) widget.controller.select(next);
  }

  void _onPointerEnd(PointerEvent event) {
    _dragging = false;
    _touches.remove(event.pointer);
    // Only a finger lifting counts: a cancel (a menu opening over the grid
    // sends one, wrongly marked as touch) is not a touch.
    if (event is PointerUpEvent && event.kind == PointerDeviceKind.touch && _touches.isEmpty) {
      widget.controller.setAutoDensity(SheetDensity.touch);
    }
    if (_touches.length < 2 && _pinching) {
      setState(() => _pinchStartDistance = null);
    }
    if (_touches.isEmpty) {
      _setTouchDragging(false);
      _lastTouch = null;
      _autoScroll?.cancel();
      _autoScroll = null;
    }
  }

  /// A long press on a cell: selects it and starts range mode; the same
  /// finger can then drag to extend.
  void _onCellLongPress(int row, int column) {
    if (_lastPointerKind != null && _isMouseLike(_lastPointerKind!)) return;
    _focus.requestFocus();
    HapticFeedback.selectionClick();
    widget.controller.select(GridSelection.cell(row, column));
    _draggingStartHandle = false;
    _setTouchDragging(true);
  }

  /// Moves the dragged corner of the selection to the cell under
  /// [position], and scrolls when the finger nears an edge.
  void _extendTouch(Offset position) {
    _lastTouch = position;
    _extendTo(position);
    _updateAutoScroll(position);
  }

  void _extendTo(Offset position) {
    final controller = widget.controller;
    final current = controller.selection.value;
    if (current == null) return;
    final cell = _cellAt(_clampToGrid(position));
    if (cell == null) return;
    final (row, column) = cell;
    final bounds = current.bounds(rowCount: controller.currentRows.length, columnCount: controller.columnCount);
    final GridSelection next;
    if (_draggingStartHandle) {
      // The start handle moves the top-left corner; the bottom-right stays.
      next = GridSelection.cell(bounds.lastRow, bounds.lastColumn).extendedTo(row, column);
    } else if (current.kind == GridSelectionKind.range || current.isSingleCell) {
      next = current.extendedTo(row, column);
    } else {
      next = GridSelection.cell(bounds.firstRow, bounds.firstColumn).extendedTo(row, column);
    }
    if (next != current) {
      controller.select(next);
      // A small tick for every cell the selection grows or shrinks by.
      HapticFeedback.selectionClick();
    }
  }

  /// Keeps a finger past the last cell (or over a header) on the nearest
  /// cell, so a drag to the edge still selects up to it.
  Offset _clampToGrid(Offset position) {
    final zoom = widget.controller.zoom;
    final left = widget.controller.metrics.rowHeaderWidth * zoom + 1;
    final top = widget.controller.metrics.headerHeight * zoom + 1;
    return Offset(
      position.dx.clamp(left, math.max(left, _viewport.width - 1)),
      position.dy.clamp(top, math.max(top, _viewport.height - 1)),
    );
  }

  /// Within this distance of an edge, a selection drag scrolls the grid.
  static const _autoScrollEdge = 40.0;

  void _updateAutoScroll(Offset position) {
    final near = _edgeVelocity(position) != Offset.zero;
    if (near && _autoScroll == null) {
      _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) => _autoScrollTick());
    } else if (!near) {
      _autoScroll?.cancel();
      _autoScroll = null;
    }
  }

  /// Pixels per tick to scroll for a finger at [position]: faster the
  /// closer it is to the edge.
  Offset _edgeVelocity(Offset position) {
    final zoom = widget.controller.zoom;
    final top = widget.controller.metrics.headerHeight * zoom;
    final left = widget.controller.metrics.rowHeaderWidth * zoom;
    double speed(double distance) => distance >= _autoScrollEdge ? 0 : 4 + 16 * (1 - distance / _autoScrollEdge);
    var dx = 0.0;
    var dy = 0.0;
    if (position.dy > _viewport.height - _autoScrollEdge) dy = speed(_viewport.height - position.dy);
    if (position.dy < top + _autoScrollEdge) dy = -speed(math.max(0, position.dy - top));
    if (position.dx > _viewport.width - _autoScrollEdge) dx = speed(_viewport.width - position.dx);
    if (position.dx < left + _autoScrollEdge) dx = -speed(math.max(0, position.dx - left));
    return Offset(dx, dy);
  }

  void _autoScrollTick() {
    final position = _lastTouch;
    if (!mounted || position == null || !(_touchDragging || _handleActive)) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    final velocity = _edgeVelocity(position);
    void scroll(ScrollController c, double delta) {
      if (!c.hasClients || delta == 0) return;
      c.jumpTo((c.offset + delta).clamp(0.0, c.position.maxScrollExtent));
    }

    scroll(widget.controller.verticalController, velocity.dy);
    scroll(widget.controller.horizontalController, velocity.dx);
    _extendTo(position);
  }

  /// Where the cell at [row], [column] sits on the grid, or null when it
  /// is hidden.
  Rect? _rectOf(int row, int column) {
    final controller = widget.controller;
    final grid = controller.geometry;
    final r = grid.visibleIndexOfRow(row);
    final c = grid.visibleIndexOfColumn(column);
    if (r == null || c == null) return null;
    final zoom = controller.zoom;
    final h = controller.horizontalController;
    final v = controller.verticalController;
    final x =
        (controller.metrics.rowHeaderWidth + grid.columnStart(c)) * zoom -
        (c < grid.frozenColumnCount || !h.hasClients ? 0 : h.offset);
    final y =
        (controller.metrics.headerHeight + grid.rowStart(r)) * zoom -
        (r < grid.frozenRowCount || !v.hasClients ? 0 : v.offset);
    return Rect.fromLTWH(x, y, grid.columnWidth(c) * zoom, grid.rowHeight(r) * zoom);
  }

  /// The two touch handles at the selection's corners, while they are on
  /// screen.
  List<Widget> _handles(BuildContext context, GridSelection selection, Color accent) {
    final controller = widget.controller;
    final bounds = selection.bounds(rowCount: controller.currentRows.length, columnCount: controller.columnCount);
    final start = _rectOf(bounds.firstRow, bounds.firstColumn)?.topLeft;
    final end = _rectOf(bounds.lastRow, bounds.lastColumn)?.bottomRight;
    final zoom = controller.zoom;
    final visible = Rect.fromLTRB(
      controller.metrics.rowHeaderWidth * zoom - 1,
      controller.metrics.headerHeight * zoom - 1,
      _viewport.width + 1,
      _viewport.height + 1,
    );
    final strings = DocumentViewerStrings.of(context);
    Widget handle(Offset at, {required bool isStart}) => Positioned(
      left: at.dx - _SelectionHandle.hitSize / 2,
      top: at.dy - _SelectionHandle.hitSize / 2,
      child: _SelectionHandle(
        accent: accent,
        key: ValueKey(isStart ? 'selection-handle-start' : 'selection-handle-end'),
        semanticsLabel: isStart ? strings.selectionStartHandle : strings.selectionEndHandle,
        onGrab: (global) {
          final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
          _draggingStartHandle = isStart;
          // Where the finger touched down, relative to the corner: the corner
          // then moves exactly as the finger does, with no jump on pick-up.
          _grabOffset = box == null ? Offset.zero : at - box.globalToLocal(global);
          _setHandleActive(true);
        },
        onDragUpdate: (global) {
          final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
          if (box == null) return;
          // The corner follows the finger; a nudge inward picks the cell
          // the corner belongs to, not its neighbour across the line.
          final nudge = isStart ? const Offset(2, 2) : const Offset(-2, -2);
          _extendTouch(box.globalToLocal(global) + _grabOffset + nudge);
        },
        onDragEnd: () {
          _draggingStartHandle = false;
          _autoScroll?.cancel();
          _autoScroll = null;
          _setHandleActive(false);
        },
      ),
    );
    return [
      if (start != null && visible.contains(start)) handle(start, isStart: true),
      if (end != null && visible.contains(end)) handle(end, isStart: false),
    ];
  }

  /// A tap on a cell: the active cell opens its details; any other cell
  /// is selected (Shift extends).
  void _onCellTap(int row, int column, VoidCallback showDetails) {
    _focus.requestFocus();
    final before = _selectionBeforeDown;
    final wasActive = before != null && before.isSingleCell && before.activeRow == row && before.activeColumn == column;
    if (wasActive && !_shift) {
      showDetails();
    } else if (!_pointerSelected) {
      final current = widget.controller.selection.value;
      final extend = _shift && current != null && (current.isSingleCell || current.kind == GridSelectionKind.range);
      widget.controller.select(extend ? current.extendedTo(row, column) : GridSelection.cell(row, column));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    _setKeyboardUsed(true);
    final controller = widget.controller;
    final keys = HardwareKeyboard.instance;
    final shift = keys.isShiftPressed;
    final command = keys.isControlPressed || keys.isMetaPressed;
    final key = event.logicalKey;
    final selected = controller.selection.value != null;
    final grid = controller.geometry;

    if (command && key == LogicalKeyboardKey.keyA) {
      controller.selectAll();
      return KeyEventResult.handled;
    }
    // Zoom from the keyboard, as in a browser: Ctrl/Cmd with +, - or 0.
    if (command) {
      if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd) {
        controller.zoomIn();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) {
        controller.zoomOut();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
        controller.setZoom(1);
        return KeyEventResult.handled;
      }
    }
    if (command && key == LogicalKeyboardKey.keyC && selected) {
      _copySelection();
      return KeyEventResult.handled;
    }
    // Esc and Tab only mean something to a grid with a selection; without
    // one they stay with the app (close search, move focus on).
    if (key == LogicalKeyboardKey.escape) {
      if (!selected) return KeyEventResult.ignored;
      controller.clearSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && !selected) return KeyEventResult.ignored;

    final last = (
      row: grid.visibleRows.isEmpty ? 0 : grid.visibleRows.last,
      column: grid.visibleColumns.isEmpty ? 0 : grid.visibleColumns.last,
    );
    if (key == LogicalKeyboardKey.arrowDown) {
      controller.moveSelection(rows: 1, extend: shift);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      controller.moveSelection(rows: -1, extend: shift);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      controller.moveSelection(columns: 1, extend: shift);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      controller.moveSelection(columns: -1, extend: shift);
    } else if (key == LogicalKeyboardKey.tab) {
      controller.moveSelection(columns: shift ? -1 : 1);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      controller.moveSelection(rows: shift ? -1 : 1);
    } else if (key == LogicalKeyboardKey.pageDown) {
      controller.moveSelection(rows: controller.pageRows, extend: shift);
    } else if (key == LogicalKeyboardKey.pageUp) {
      controller.moveSelection(rows: -controller.pageRows, extend: shift);
    } else if (key == LogicalKeyboardKey.home) {
      controller.moveSelectionTo(row: command ? 0 : null, column: 0, extend: shift);
    } else if (key == LogicalKeyboardKey.end) {
      controller.moveSelectionTo(row: command ? last.row : null, column: last.column, extend: shift);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Whether the grid is in its mouse layout (compact rows): draggable
  /// scrollbars in their own gutters, column resize handles.
  bool get _mouseLayout => widget.controller.density == SheetDensity.compact;

  /// Width of the scrollbar gutters in the mouse layout; 0 otherwise or
  /// without scrollbars.
  double get _gutter => widget.showScrollbars && _mouseLayout ? 14 : 0;

  /// The table over a ghost grid (faint lines past the data, so a small
  /// sheet fills the view), inside scrollbars when they are on.
  Widget _gridArea(BuildContext context, Color accent) {
    final controller = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    final pixel = 1 / MediaQuery.devicePixelRatioOf(context);
    final ghost = Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _GhostGridPainter(
            geometry: controller.geometry,
            metrics: controller.metrics,
            zoom: controller.zoom,
            horizontalOffset: controller.horizontalController.hasClients ? controller.horizontalController.offset : 0,
            verticalOffset: controller.verticalController.hasClients ? controller.verticalController.offset : 0,
            lineColor: scheme.outlineVariant.withValues(alpha: 0.7),
            headerColor: scheme.surfaceContainerLow,
            lineWidth: math.max(0.5, pixel),
          ),
        ),
      ),
    );
    final table = Positioned.fill(child: _buildTable(context, accent));
    if (!widget.showScrollbars) return Stack(children: [ghost, table]);
    final vertical = controller.verticalController;
    final horizontal = controller.horizontalController;
    bool onAxis(ScrollNotification n, Axis axis) => n.metrics.axis == axis;
    if (!_mouseLayout) {
      // Thumbs that show while scrolling, over the grid, and fade out.
      return Scrollbar(
        controller: vertical,
        notificationPredicate: (n) => onAxis(n, Axis.vertical),
        child: Scrollbar(
          controller: horizontal,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          notificationPredicate: (n) => onAxis(n, Axis.horizontal),
          child: Stack(children: [ghost, table]),
        ),
      );
    }
    // The ghost grid runs under the scrollbar gutters too, so a small sheet
    // has no blank strips at its right and bottom.
    return Stack(
      children: [
        ghost,
        Scrollbar(
          controller: vertical,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          thickness: 10,
          radius: const Radius.circular(5),
          notificationPredicate: (n) => onAxis(n, Axis.vertical),
          child: Scrollbar(
            controller: horizontal,
            thumbVisibility: true,
            trackVisibility: true,
            interactive: true,
            thickness: 10,
            radius: const Radius.circular(5),
            scrollbarOrientation: ScrollbarOrientation.bottom,
            notificationPredicate: (n) => onAxis(n, Axis.horizontal),
            child: Padding(
              padding: EdgeInsets.only(right: _gutter, bottom: _gutter),
              child: Stack(children: [table]),
            ),
          ),
        ),
      ],
    );
  }

  /// Table row 0 is the column-letter header and table column 0 the row
  /// numbers; the sheet's visible rows/columns follow.
  Widget _buildTable(BuildContext context, Color accent) {
    final controller = widget.controller;
    final geometry = controller.geometry;
    final zoom = controller.zoom;
    final merges = _mergesOf(geometry);
    final rows = controller.currentRows;
    final selection = controller.selection.value;
    final selectionBounds = selection?.bounds(rowCount: rows.length, columnCount: controller.columnCount);

    return TableView.builder(
      // In range mode and while pinching, a finger selects or zooms; it
      // doesn't scroll (auto-scroll at the edges moves the grid instead).
      verticalDetails: ScrollableDetails.vertical(
        controller: controller.verticalController,
        physics: _lockScroll ? const NeverScrollableScrollPhysics() : null,
      ),
      horizontalDetails: ScrollableDetails.horizontal(
        controller: controller.horizontalController,
        physics: _lockScroll ? const NeverScrollableScrollPhysics() : null,
      ),
      rowCount: geometry.visibleRows.length + 1,
      columnCount: geometry.visibleColumns.length + 1,
      pinnedRowCount: geometry.frozenRowCount + 1,
      pinnedColumnCount: geometry.frozenColumnCount + 1,
      rowBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent((i == 0 ? controller.metrics.headerHeight : geometry.rowHeight(i - 1)) * zoom),
      ),
      columnBuilder: (i) => TableSpan(
        extent: FixedTableSpanExtent((i == 0 ? controller.metrics.rowHeaderWidth : geometry.columnWidth(i - 1)) * zoom),
      ),
      cellBuilder: (context, vicinity) {
        final r = vicinity.row;
        final c = vicinity.column;
        if (r == 0 && c == 0) {
          return TableViewCell(
            child: _Corner(
              accent: accent,
              selected: selection?.kind == GridSelectionKind.all,
              semanticsLabel: DocumentViewerStrings.of(context).selectAll,
              onTap: () {
                _focus.requestFocus();
                selection?.kind == GridSelectionKind.all ? controller.clearSelection() : controller.selectAll();
              },
            ),
          );
        }
        if (r == 0) {
          final column = geometry.visibleColumns[c - 1];
          return TableViewCell(
            child: _HeaderCell(
              label: columnLabel(column),
              zoom: zoom,
              isColumn: true,
              accent: accent,
              selected: selection == GridSelection.column(column),
              highlighted:
                  selectionBounds != null &&
                  selection?.kind != GridSelectionKind.row &&
                  column >= selectionBounds.firstColumn &&
                  column <= selectionBounds.lastColumn,
              semanticsLabel: DocumentViewerStrings.of(context).column(columnLabel(column)),
              onTap: () => _toggleSelection(GridSelection.column(column)),
              // A mouse can drag a column's right edge to resize it (this
              // view only), or double-click it to fit the text.
              trailing: controller.density == SheetDensity.compact
                  ? Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: 8,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (details) =>
                              controller.setColumnWidth(column, geometry.columnWidth(c - 1) + details.delta.dx / zoom),
                          onDoubleTap: () => _fitColumn(context, column),
                        ),
                      ),
                    )
                  // By touch: a long press on a header's right edge starts
                  // resizing at once, and the same finger drags the edge.
                  : Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: 28,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPressStart: (details) {
                          HapticFeedback.selectionClick();
                          _focus.requestFocus();
                          controller.select(GridSelection.column(column));
                          _beginResize(column, details.globalPosition);
                        },
                        onLongPressMoveUpdate: (details) => _resizeTo(column, details.globalPosition),
                        onLongPressEnd: (_) => _setResizing(null),
                        onLongPressCancel: () => _setResizing(null),
                      ),
                    ),
            ),
          );
        }
        if (c == 0) {
          final row = geometry.visibleRows[r - 1];
          return TableViewCell(
            child: _HeaderCell(
              label: '${row + 1}',
              zoom: zoom,
              isColumn: false,
              accent: accent,
              selected: selection == GridSelection.row(row),
              highlighted:
                  selectionBounds != null &&
                  selection?.kind != GridSelectionKind.column &&
                  row >= selectionBounds.firstRow &&
                  row <= selectionBounds.lastRow,
              semanticsLabel: DocumentViewerStrings.of(context).row(row + 1),
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
        final isActive =
            selection != null &&
            (selection.isSingleCell || selection.kind == GridSelectionKind.range) &&
            selection.activeRow == row &&
            selection.activeColumn == column;
        void openDetails() => _showCellDetail(
          context,
          address: '${columnLabel(column)}${row + 1}',
          // A formula saved without its result has no value to show.
          value: switch (data?.value) {
            FormulaValue(cached: null) => '',
            _ => data?.text ?? '',
          },
          formula: data?.formulaText,
          comment: comment,
          link: link,
          onOpenInternalLink: controller.openInternalLink,
        );
        return TableViewCell(
          rowMergeStart: merge?.rowStart,
          rowMergeSpan: merge?.rowSpan,
          columnMergeStart: merge?.columnStart,
          columnMergeSpan: merge?.columnSpan,
          child: _DataCell(
            accent: accent,
            paddingX: controller.metrics.paddingX,
            paddingY: controller.metrics.paddingY,
            onSecondaryTap: (position) => _showCellMenu(context, position, row, column, openDetails),
            address: '${columnLabel(column)}${row + 1}',
            data: data,
            highlight: highlight,
            zoom: zoom,
            isLink: link != null,
            hasComment: comment != null,
            isActive: isActive,
            edges: selectionBounds != null && (selection?.contains(row, column) ?? false)
                ? _SelectionEdges(
                    top: row == selectionBounds.firstRow,
                    bottom: row == selectionBounds.lastRow,
                    left: column == selectionBounds.firstColumn,
                    right: column == selectionBounds.lastColumn,
                  )
                : null,
            onLongPress: () => _onCellLongPress(row, column),
            onTap: () => _onCellTap(row, column, openDetails),
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
        for (var r = range.firstRow; r <= math.min(range.lastRow, lastRow); r++) ?geometry.visibleIndexOfRow(r),
      ];
      final columns = [
        for (var c = range.firstColumn; c <= math.min(range.lastColumn, lastColumn); c++)
          ?geometry.visibleIndexOfColumn(c),
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

/// Faint grid lines (and a header bar) in the space past the sheet's data,
/// so a small sheet fills the view. Painted behind the table, whose cells
/// cover their own area; lines continue the real rows and columns, then
/// default-sized ones.
class _GhostGridPainter extends CustomPainter {
  _GhostGridPainter({
    required this.geometry,
    required this.metrics,
    required this.zoom,
    required this.horizontalOffset,
    required this.verticalOffset,
    required this.lineColor,
    required this.headerColor,
    required this.lineWidth,
  });

  final SheetGeometry geometry;
  final SheetMetrics metrics;
  final double zoom;
  final double horizontalOffset;
  final double verticalOffset;
  final Color lineColor;
  final Color headerColor;
  final double lineWidth;

  static const _maxLines = 400;

  @override
  void paint(Canvas canvas, Size size) {
    final headerWidth = metrics.rowHeaderWidth * zoom;
    final headerHeight = metrics.headerHeight * zoom;
    final right = (metrics.rowHeaderWidth + geometry.contentWidth) * zoom - horizontalOffset;
    final bottom = (metrics.headerHeight + geometry.contentHeight) * zoom - verticalOffset;
    final gapRight = right < size.width - 1;
    final gapBottom = bottom < size.height - 1;
    if (!gapRight && !gapBottom) return;

    final fill = Paint()..color = headerColor;
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = lineWidth;
    if (gapRight) canvas.drawRect(Rect.fromLTRB(right, 0, size.width, headerHeight), fill);
    if (gapBottom) canvas.drawRect(Rect.fromLTRB(0, bottom, headerWidth, size.height), fill);

    // Column edges: the real ones (below the data) then default ones (right of it).
    final xs = <(double, bool)>[]; // (x, isGhost)
    if (gapBottom) {
      for (var i = 0; i < geometry.visibleColumns.length && xs.length < _maxLines; i++) {
        final x =
            (metrics.rowHeaderWidth + geometry.columnStart(i + 1)) * zoom -
            (i < geometry.frozenColumnCount ? 0 : horizontalOffset);
        if (x > headerWidth && x <= size.width) xs.add((x, false));
      }
    }
    if (gapRight) {
      final step = metrics.columnWidth * zoom;
      for (var x = right + step, n = 0; x < size.width + step && n < _maxLines; x += step, n++) {
        xs.add((x, true));
      }
    }
    final ys = <(double, bool)>[];
    if (gapRight) {
      for (var i = 0; i < geometry.visibleRows.length && ys.length < _maxLines; i++) {
        final y =
            (metrics.headerHeight + geometry.rowStart(i + 1)) * zoom -
            (i < geometry.frozenRowCount ? 0 : verticalOffset);
        if (y > headerHeight && y <= size.height) ys.add((y, false));
      }
    }
    if (gapBottom) {
      final step = metrics.rowHeight * zoom;
      for (var y = bottom + step, n = 0; y < size.height + step && n < _maxLines; y += step, n++) {
        ys.add((y, true));
      }
    }
    for (final (x, ghost) in xs) {
      canvas.drawLine(Offset(x, ghost ? 0 : math.max(bottom, headerHeight)), Offset(x, size.height), line);
    }
    for (final (y, ghost) in ys) {
      canvas.drawLine(Offset(ghost ? 0 : math.max(right, headerWidth), y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GhostGridPainter old) =>
      old.geometry != geometry ||
      old.metrics != metrics ||
      old.zoom != zoom ||
      old.horizontalOffset != horizontalOffset ||
      old.verticalOffset != verticalOffset ||
      old.lineColor != lineColor ||
      old.headerColor != headerColor ||
      old.lineWidth != lineWidth;
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

/// Full value of a cell, which the grid truncates, with Copy and,
/// for a linked cell, Open link. A formula cell also shows its [formula]
/// (as Excel's formula bar does, with its own Copy), and a noted cell its
/// [comment]. Web links open outside the app (`http`,
/// `https` and `mailto` only); a link to a place in the workbook
/// (`#Sheet2!A1`) goes to [onOpenInternalLink].
Future<void> _showCellDetail(
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
    builder: (sheetContext) {
      final strings = DocumentViewerStrings.of(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(strings.cell(address), style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.5),
                child: SingleChildScrollView(
                  child: SelectableText(
                    value.isNotEmpty
                        ? value
                        : formula != null
                        ? strings.formulaWithoutResult
                        : '(empty)',
                    style: value.isEmpty
                        ? Theme.of(
                            sheetContext,
                          ).textTheme.bodyMedium?.copyWith(color: Theme.of(sheetContext).colorScheme.onSurfaceVariant)
                        : Theme.of(sheetContext).textTheme.bodyLarge,
                  ),
                ),
              ),
              if (formula != null) ...[
                const SizedBox(height: 16),
                Text(strings.formula, style: Theme.of(sheetContext).textTheme.labelMedium),
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
                      tooltip: strings.copyFormula,
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        _copyText(context, formula, strings.formula);
                        Navigator.of(sheetContext).pop();
                      },
                    ),
                  ],
                ),
              ],
              if (comment != null) ...[
                const SizedBox(height: 16),
                Text(strings.note(author: comment.author), style: Theme.of(sheetContext).textTheme.labelMedium),
                const SizedBox(height: 4),
                SelectableText(comment.text, style: Theme.of(sheetContext).textTheme.bodyMedium),
              ],
              if (link != null) ...[
                const SizedBox(height: 8),
                Text(
                  link,
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
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
                      label: Text(strings.openLink),
                    ),
                  FilledButton.icon(
                    onPressed: value.isEmpty
                        ? null
                        : () {
                            _copyText(context, value, strings.cell(address));
                            Navigator.of(sheetContext).pop();
                          },
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(strings.copy),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A header's fill: quiet, with a tint of [accent] while it is part of the
/// selection.
Color _headerFill(ColorScheme scheme, Color accent, bool on) =>
    on ? Color.alphaBlend(accent.withValues(alpha: 0.18), scheme.surfaceContainerLow) : scheme.surfaceContainerLow;

class _Corner extends StatelessWidget {
  const _Corner({required this.selected, required this.accent, required this.semanticsLabel, required this.onTap});

  final bool selected;
  final Color accent;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        canRequestFocus: false,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _headerFill(scheme, accent, selected),
            border: Border.all(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
      ),
    );
  }
}

/// A column letter or row number. [highlighted] marks one the selection
/// touches: accent text and tint, and a bar on its inner edge (below a
/// column letter, right of a row number) so it never relies on colour alone.
/// [trailing] sits over its far edge (the column resize handle).
class _HeaderCell extends StatelessWidget {
  final String label;
  final double zoom;
  final bool selected;
  final bool highlighted;
  final bool isColumn;
  final Color accent;
  final String semanticsLabel;
  final VoidCallback onTap;
  final Widget? trailing;

  const _HeaderCell({
    required this.label,
    required this.zoom,
    required this.selected,
    required this.highlighted,
    required this.isColumn,
    required this.accent,
    required this.semanticsLabel,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = highlighted || selected;
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            button: true,
            selected: selected,
            label: semanticsLabel,
            excludeSemantics: true,
            child: InkWell(
              canRequestFocus: false,
              onTap: onTap,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _headerFill(scheme, accent, on),
                  border: Border.all(color: scheme.outlineVariant, width: 0.5),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 12 * zoom,
                    color: on ? accent : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Before the bar: children are matched by position, so a selection
        // that adds the bar must not shift (and rebuild) this zone mid-gesture.
        ?trailing,
        if (on)
          Positioned(
            left: isColumn ? 0 : null,
            right: 0,
            bottom: isColumn ? 0 : 0,
            top: isColumn ? null : 0,
            width: isColumn ? null : 2.5,
            height: isColumn ? 2.5 : null,
            child: IgnorePointer(child: ColoredBox(color: accent)),
          ),
      ],
    );
  }
}

/// What the selection bar shows: like a spreadsheet's status bar, the
/// numbers' Sum, Average, Min and Max.
///
/// Dates and times are left out of the numbers (adding date serials is
/// meaningless), and when every number shares one format (currency,
/// percent, ...) the results are shown in it, so a column of 10% and 20%
/// sums to 30%, not 0.3.
class SelectionSummary {
  /// Creates a summary from already gathered parts.
  const SelectionSummary({
    required this.label,
    required this.address,
    required this.values,
    required this.numbers,
    this.dimensions,
    this.skipped = false,
    this.numberFormat,
  });

  /// Ranges bigger than this are not summed, to keep the grid responsive.
  static const maxSummarizedCells = 100000;

  /// Summarises the cells of [rows] under [selection]; a row selection
  /// covers [columnCount] columns. [strings] supplies the label.
  factory SelectionSummary.of(
    List<List<SheetCell?>> rows,
    int columnCount,
    GridSelection selection,
    DocumentViewerStrings strings,
  ) {
    final bounds = selection.bounds(rowCount: rows.length, columnCount: columnCount);
    final rowSpan = bounds.lastRow - bounds.firstRow + 1;
    final columnSpan = bounds.lastColumn - bounds.firstColumn + 1;
    final address = selection.address(rowCount: rows.length, columnCount: columnCount);
    final label = switch (selection.kind) {
      GridSelectionKind.row => strings.row(selection.index + 1),
      GridSelectionKind.column => strings.column(columnLabel(selection.index)),
      _ => address,
    };
    final dimensions = selection.kind == GridSelectionKind.cell ? null : strings.dimensions(rowSpan, columnSpan);
    // A whole row or column is always summed; a range is capped.
    if (!(selection.isRow || selection.isColumn) && rowSpan * columnSpan > maxSummarizedCells) {
      return SelectionSummary(
        label: label,
        address: address,
        values: const [],
        numbers: const [],
        dimensions: dimensions,
        skipped: true,
      );
    }
    final values = <String>[];
    final numbers = <num>[];
    final formats = <String>{};
    NumberFormat? format;
    for (var r = bounds.firstRow; r <= bounds.lastRow; r++) {
      for (var c = bounds.firstColumn; c <= bounds.lastColumn; c++) {
        final cell = r < rows.length && c < rows[r].length ? rows[r][c] : null;
        values.add(cell?.text ?? '');
        final number = cell?.number;
        if (cell == null || number == null || cell.style.numberFormat.isDate) continue;
        numbers.add(number);
        formats.add(cell.style.numberFormat.code);
        format = cell.style.numberFormat;
      }
    }
    return SelectionSummary(
      label: label,
      address: address,
      values: values,
      numbers: numbers,
      dimensions: dimensions,
      numberFormat: formats.length == 1 && !(format?.isGeneral ?? true) ? format : null,
    );
  }

  /// What is selected: "Row 3", "Column B", or the address "B2:D5".
  final String label;

  /// The selection in Excel's notation (`B2:D5`, `3:3`, `B:B`).
  final String address;

  /// Every cell's shown text, in order, blanks included.
  final List<String> values;

  /// The number cells' values (see [SheetCell.number]), in order, without
  /// dates and times.
  final List<num> numbers;

  /// "4R × 3C" for a range; null for a single cell.
  final String? dimensions;

  /// Whether the range was too big to summarise.
  final bool skipped;

  /// The format every number shares, used to show the results; null when
  /// they differ or are all General.
  final NumberFormat? numberFormat;

  /// How many cells show any text.
  int get count => values.where((v) => v.isNotEmpty).length;

  /// How many cells are numbers.
  int get numericCount => numbers.length;

  /// Sum of [numbers]; 0 when there are none.
  num get sum => numbers.fold<num>(0, (a, b) => a + b);

  /// Mean of [numbers]; null when there are none.
  double? get average => numbers.isEmpty ? null : sum / numbers.length;

  /// Smallest of [numbers]; null when there are none.
  num? get min => numbers.isEmpty ? null : numbers.reduce((a, b) => a < b ? a : b);

  /// Largest of [numbers]; null when there are none.
  num? get max => numbers.isEmpty ? null : numbers.reduce((a, b) => a > b ? a : b);

  /// [value] as the cells show numbers: in the shared [numberFormat], else
  /// plainly.
  String show(num value) => numberFormat?.format(value) ?? _formatNumber(value);
}

String _formatNumber(num n) {
  final rounded = n is double ? double.parse(n.toStringAsFixed(4)) : n;
  return rounded == rounded.roundToDouble() && rounded.abs() < 1e15 ? rounded.toInt().toString() : rounded.toString();
}

/// Copies [text] and says so, or says why not. Uses the messenger above
/// [context] (which must still be mounted).
Future<void> _copyText(BuildContext context, String text, String what) async {
  final strings = DocumentViewerStrings.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  String message;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    message = strings.copied(what);
  } catch (_) {
    message = strings.couldNotCopy;
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _SelectionBar extends StatelessWidget {
  final SelectionSummary summary;
  final VoidCallback onClear;
  final VoidCallback onCopy;

  const _SelectionBar({
    required this.accent,
    required this.summary,
    required this.onClear,
    required this.onCopy,
    this.columnWidthActions,
  });

  final Color accent;

  /// For a selected column: fit it to its content, and restore the file's
  /// width (null when the reader hasn't changed it).
  final ({VoidCallback fit, VoidCallback? reset})? columnWidthActions;

  @override
  Widget build(BuildContext context) {
    final average = summary.average;
    final strings = DocumentViewerStrings.of(context);
    final details = [
      ?summary.dimensions,
      if (!summary.skipped) ...[
        // Excel's status-bar wording, short enough for a phone.
        strings.count(summary.count),
        // Said only when some of the cells are not numbers, so a total is
        // never mistaken for a total of everything.
        if (summary.numericCount > 0 && summary.numericCount != summary.count) strings.numbers(summary.numericCount),
        if (summary.numbers.isNotEmpty) strings.sum(summary.show(summary.sum)),
        if (average != null) strings.average(summary.show(average)),
        if (summary.min != null) strings.min(summary.show(summary.min!)),
        if (summary.max != null) strings.max(summary.show(summary.max!)),
      ] else
        strings.rangeTooLargeToSummarize,
    ].join(' · ');
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${strings.selected(summary.label)}, $details',
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 0.5)),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: summary.label,
                      style: TextStyle(fontWeight: FontWeight.bold, color: accent),
                    ),
                    TextSpan(text: '  $details'),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
            IconButton(
              tooltip: strings.copySelection(summary.label),
              icon: const Icon(Icons.copy_rounded, size: 20),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              onPressed: onCopy,
            ),
            if (columnWidthActions case final actions?)
              PopupMenuButton<String>(
                tooltip: strings.columnWidth,
                icon: Icon(Icons.swap_horiz_rounded, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                onSelected: (value) => value == 'fit' ? actions.fit() : actions.reset?.call(),
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'fit', child: Text(strings.fitColumn)),
                  PopupMenuItem(value: 'reset', enabled: actions.reset != null, child: Text(strings.resetColumn)),
                ],
              ),
            IconButton(
              tooltip: strings.copyAddress,
              icon: const Icon(Icons.tag_rounded, size: 20),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              onPressed: () => _copyText(context, summary.address, summary.address),
            ),
            IconButton(
              tooltip: strings.clearSelection,
              icon: const Icon(Icons.close_rounded, size: 20),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

/// The grip on a selected column's right edge: drag to resize the column on
/// screen, double-tap to fit its text. The pill is small, the touch zone is
/// 48 px wide (centred on the edge between two headers).
class _ColumnGrip extends StatelessWidget {
  const _ColumnGrip({
    required this.accent,
    required this.semanticsLabel,
    required this.onGrab,
    required this.onDrag,
    required this.onEnd,
    required this.onFit,
  });

  static const hitWidth = 48.0;

  final Color accent;
  final String semanticsLabel;
  final ValueChanged<Offset> onGrab;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onEnd;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticsLabel,
      child: GestureDetector(
        key: const Key('column-resize-grip'),
        behavior: HitTestBehavior.opaque,
        onPanDown: (details) => onGrab(details.globalPosition),
        onPanStart: (details) => onDrag(details.globalPosition),
        onPanUpdate: (details) => onDrag(details.globalPosition),
        onPanEnd: (_) => onEnd(),
        onPanCancel: onEnd,
        onDoubleTap: onFit,
        child: Center(
          child: Container(
            width: 8,
            height: 26,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: scheme.surface, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round touch handle at a corner of the selection, with a hit area big
/// enough for a finger.
class _SelectionHandle extends StatelessWidget {
  const _SelectionHandle({
    super.key,
    required this.accent,
    required this.semanticsLabel,
    required this.onGrab,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  /// The square a finger can grab (at least 44 logical px).
  static const hitSize = 48.0;
  static const _dotSize = 12.0;

  final Color accent;
  final String semanticsLabel;

  /// A finger went down on the handle (scrolling stops at once, before the
  /// drag is recognised).
  final ValueChanged<Offset> onGrab;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanDown: (details) => onGrab(details.globalPosition),
        // The position where the drag was recognised counts as an update.
        onPanStart: (details) => onDragUpdate(details.globalPosition),
        onPanUpdate: (details) => onDragUpdate(details.globalPosition),
        onPanEnd: (_) => onDragEnd(),
        onPanCancel: onDragEnd,
        child: SizedBox.square(
          dimension: hitSize,
          child: Center(
            child: Container(
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: BoxShape.circle,
                border: Border.all(color: accent, width: 2.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which sides of a selected cell lie on the selection's outline.
class _SelectionEdges {
  const _SelectionEdges({required this.top, required this.bottom, required this.left, required this.right});

  final bool top;
  final bool bottom;
  final bool left;
  final bool right;
}

enum _CellHighlight { none, match, current, selected }

class _DataCell extends StatelessWidget {
  final Color accent;
  final double paddingX;
  final double paddingY;
  final void Function(Offset position)? onSecondaryTap;
  final String address;
  final SheetCell? data;
  final _CellHighlight highlight;
  final double zoom;
  final bool isLink;
  final bool hasComment;
  final bool isActive;
  final _SelectionEdges? edges;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _DataCell({
    required this.accent,
    required this.paddingX,
    required this.paddingY,
    this.onSecondaryTap,
    required this.address,
    required this.data,
    required this.highlight,
    required this.zoom,
    required this.isLink,
    required this.onTap,
    this.hasComment = false,
    this.isActive = false,
    this.edges,
    this.onLongPress,
  });

  /// Office's default font size; the grid draws it at 13 logical px.

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = data?.style ?? CellStyle.plain;
    final background = style.fillColor == null ? null : Color(style.fillColor!);
    // Theme colours, not a hard-coded orange: the current match
    // stands out, other matches are marked lightly.
    final highlights = DocumentViewerTheme.of(context);
    // A selected cell keeps its own fill and text, under a light tint of the
    // selection colour; the active cell is left untinted (its border marks
    // it), so it reads as "where the keyboard is" inside a range.
    final fill = switch (highlight) {
      _CellHighlight.current => highlights.currentMatchBackground,
      _CellHighlight.match => highlights.matchBackground!.withValues(alpha: 0.5),
      _CellHighlight.selected when isActive => background,
      _CellHighlight.selected => Color.alphaBlend(accent.withValues(alpha: 0.14), background ?? scheme.surface),
      _CellHighlight.none => background,
    };
    final textColor = switch (highlight) {
      _CellHighlight.current => highlights.currentMatchForeground!,
      _CellHighlight.match => scheme.onSurface,
      _CellHighlight.selected || _CellHighlight.none => _ownTextColor(style, fill, scheme),
    };
    final decorations = [
      if (style.underline || isLink) TextDecoration.underline,
      if (style.strikethrough) TextDecoration.lineThrough,
    ];
    final bar = data?.dataBar;
    final outline = _outline(accent);
    return Semantics(
      button: true,
      selected: highlight == _CellHighlight.selected || isActive,
      label: DocumentViewerStrings.of(context).cellDescription(
        address,
        value: data?.text ?? '',
        formula: data?.value is FormulaValue,
        link: isLink,
        note: hasComment,
        selected: highlight == _CellHighlight.selected || isActive,
      ),
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: _HoverTint(
        color: isActive ? null : accent.withValues(alpha: 0.08),
        child: InkWell(
          canRequestFocus: false,
          // The grey hover wash is replaced by the accent tint of _HoverTint.
          hoverColor: Colors.transparent,
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapDown: onSecondaryTap == null ? null : (details) => onSecondaryTap!(details.globalPosition),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: paddingX * zoom, vertical: paddingY * zoom),
            alignment: _alignment(style, data?.value),
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: fill,
              border: cellBorder(
                style.borders,
                gridline: scheme.outlineVariant,
                automatic: scheme.onSurface,
                zoom: zoom,
                // One physical pixel, but never thinner than a hairline.
                gridlineWidth: math.max(0.5, 1 / MediaQuery.devicePixelRatioOf(context)),
              ),
            ),
            foregroundDecoration: outline ?? (hasComment ? _CommentMarker(color: scheme.error, size: 7 * zoom) : null),
            child: _withBar(
              bar,
              _alignment(style, data?.value),
              _text(
                style: style,
                textAlign: _textAlign(style, data?.value),
                textStyle: TextStyle(
                  color: textColor,
                  // Never below 11 px (or the file's own size, if smaller)
                  // when zoomed out.
                  fontSize: math.max(
                    SheetGeometry.fontPixelsOf(style.fontSize) * zoom,
                    math.min(SheetGeometry.fontPixelsOf(style.fontSize), 11),
                  ),
                  fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
                  fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
                  decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The cell's text. A number or date that doesn't fit shows `#` marks, as
  /// Excel does, never a shortened value that could be misread.
  Widget _text({required CellStyle style, required TextAlign textAlign, required TextStyle textStyle}) {
    final text = data?.text ?? '';
    final value = data?.value;
    final numeric = value is NumberValue || (value is FormulaValue && value.cached is NumberValue);
    if (numeric && !style.wrapText) return _NumberText(text: text, style: textStyle, textAlign: textAlign);
    return Text(
      text,
      maxLines: style.wrapText ? null : 1,
      softWrap: style.wrapText,
      overflow: style.wrapText ? TextOverflow.clip : TextOverflow.ellipsis,
      textAlign: textAlign,
      style: textStyle,
    );
  }

  /// The active cell's full border, or the selection's outline on the sides
  /// of this cell that lie on its edge. Drawn as borders, so selection never
  /// depends on colour alone.
  Decoration? _outline(Color accent) {
    final width = 2.0 * (zoom < 1 ? 1 : zoom);
    BorderSide side(bool on) => on ? BorderSide(color: accent, width: width) : BorderSide.none;
    if (isActive) {
      return BoxDecoration(
        border: Border.all(color: accent, width: width + 0.5),
      );
    }
    final e = edges;
    if (e == null || !(e.top || e.bottom || e.left || e.right)) return null;
    return BoxDecoration(
      border: Border(top: side(e.top), bottom: side(e.bottom), left: side(e.left), right: side(e.right)),
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

/// Tints its child lightly while a mouse is over it. Touch never hovers.
class _HoverTint extends StatefulWidget {
  const _HoverTint({required this.color, required this.child});

  final Color? color;
  final Widget child;

  @override
  State<_HoverTint> createState() => _HoverTintState();
}

class _HoverTintState extends State<_HoverTint> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovering = true),
    onExit: (_) => setState(() => _hovering = false),
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(color: _hovering ? widget.color : null),
      child: widget.child,
    ),
  );
}

/// A number or date on one line; when it is wider than the cell, `#` marks
/// fill the cell instead (Excel's way), so a cut-off figure is never read as
/// a different one. The full value stays in the name bar and the cell sheet.
class _NumberText extends StatelessWidget {
  const _NumberText({required this.text, required this.style, required this.textAlign});

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth;
      var shown = text;
      if (available.isFinite && text.isNotEmpty) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final fits = painter.width <= available + 0.5;
        if (!fits) {
          painter
            ..text = TextSpan(text: '#', style: style)
            ..layout();
          shown = '#' * math.max(1, (available / painter.width).floor());
        }
        painter.dispose();
      }
      return Text(shown, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, textAlign: textAlign, style: style);
    },
  );
}
