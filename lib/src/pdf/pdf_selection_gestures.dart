import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'pdf_layout.dart';
import 'pdf_selection.dart';
import 'pdf_text_layer.dart';

/// Turns pointer input over a PDF's pages into a [PdfSelectionController]'s
/// selection: a press and drag with the mouse, double and triple clicks for
/// a word and a line, dragging past the edge to scroll.
///
/// It knows nothing of widgets: [PdfView] feeds it positions and tells it
/// how the view is laid out and how to scroll.
class PdfSelectionGestures {
  /// Drives [selection] over [layout]'s pages.
  PdfSelectionGestures({
    required this.selection,
    required this.layout,
    required this.pageSize,
    required this.contentAt,
    required this.scrollBy,
    required this.viewportSize,
  });

  /// The selection to change.
  final PdfSelectionController selection;

  /// How the pages are laid out now; null before they are.
  final PdfLayout? Function() layout;

  /// A page's size in points.
  final Size Function(int page) pageSize;

  /// The content point under a point of the view.
  final Offset Function(Offset viewportPoint) contentAt;

  /// Scrolls by [delta] screen pixels.
  final void Function(Offset delta) scrollBy;

  /// The view's size on screen.
  final Size Function() viewportSize;

  /// Whether the pointer is over text, for a text cursor.
  final overText = ValueNotifier<bool>(false);

  /// How close to the view's edge a drag starts to scroll, in pixels.
  static const edge = 32.0;

  PdfCaret? _anchor;
  Offset? _viewportPoint;
  Timer? _scroller;
  DateTime? _lastDown;
  Offset? _lastDownPoint;
  int _clicks = 0;

  /// Set when a click selected a word or a line: the tap that ends it must
  /// not clear what it selected.
  bool suppressClear = false;

  /// Set when a double click selected a word: the view's double-tap zoom
  /// must skip it.
  bool suppressZoom = false;

  /// Whether the pointer is being dragged to select.
  bool get isDragging => _anchor != null && _viewportPoint != null;

  double _factor(int page) {
    final rect = layout()!.pages[page];
    return pageSize(page).width / rect.width;
  }

  /// The page nearest [content] (the one under it, when there is one).
  int? _pageAt(Offset content) {
    final pages = layout()?.pages;
    if (pages == null || pages.isEmpty) return null;
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < pages.length; i++) {
      final rect = pages[i];
      final dx = content.dx < rect.left
          ? rect.left - content.dx
          : (content.dx > rect.right ? content.dx - rect.right : 0.0);
      final dy = content.dy < rect.top
          ? rect.top - content.dy
          : (content.dy > rect.bottom ? content.dy - rect.bottom : 0.0);
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
        if (distance == 0) break;
      }
    }
    return best;
  }

  /// The pointer is over [page] at [local] (that page's pixels): note
  /// whether it is over text. Reads the page's text on first sight.
  void hover(int page, Offset local) {
    final layer = selection.layerOf(page);
    if (layer == null) {
      unawaited(selection.loadLayer(page));
      overText.value = false;
      return;
    }
    overText.value = !layer.isEmpty && layer.isOverText(local * _factor(page), slop: 2);
  }

  /// A mouse button went down on [page] at [local].
  Future<void> pointerDown(int page, Offset local) async {
    final now = DateTime.now();
    final near = _lastDownPoint != null && (local - _lastDownPoint!).distance < 18;
    _clicks = _lastDown != null && near && now.difference(_lastDown!) < kDoubleTapTimeout ? _clicks + 1 : 1;
    _lastDown = now;
    _lastDownPoint = local;
    _anchor = null;
    suppressClear = false;
    suppressZoom = false;
    final layer = await selection.loadLayer(page);
    if (layer == null || layer.isEmpty) return;
    final point = local * _factor(page);
    if (_clicks >= 2) {
      if (!layer.isOverText(point, slop: 4)) return;
      final index = layer.charAt(point);
      if (index == null) return;
      final (start, end) = _clicks == 2 ? layer.wordAt(index) : layer.lineAt(index);
      selection.select(PdfCaret(page, start), PdfCaret(page, end));
      suppressClear = true;
      suppressZoom = _clicks == 2;
      return;
    }
    _anchor = PdfCaret(page, layer.caretAt(point));
  }

  /// Starts a drag that moves one end of the selection, the other end
  /// ([anchor]) staying put: a touch handle being dragged, or a long-press
  /// that goes on to drag.
  void beginDragFrom(PdfCaret anchor) {
    _anchor = anchor;
    _viewportPoint = null;
  }

  /// The drag began; the pointer is at [viewportPoint] of the view.
  void dragStart(Offset viewportPoint) {
    _viewportPoint = viewportPoint;
    _extend();
  }

  /// The drag moved to [viewportPoint].
  void dragUpdate(Offset viewportPoint) {
    if (_anchor == null) return;
    _viewportPoint = viewportPoint;
    _extend();
    _scroller ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _scrollTick());
  }

  /// The drag ended or was cancelled.
  void dragEnd() {
    _scroller?.cancel();
    _scroller = null;
    _viewportPoint = null;
    _anchor = null;
  }

  void _extend() {
    final anchor = _anchor;
    final point = _viewportPoint;
    if (anchor == null || point == null || layout() == null) return;
    final content = contentAt(point);
    final page = _pageAt(content);
    if (page == null) return;
    final layer = selection.layerOf(page);
    if (layer == null) {
      unawaited(selection.loadLayer(page).then((_) => _extend()));
      return;
    }
    final local = content - layout()!.pages[page].topLeft;
    selection.select(anchor, PdfCaret(page, layer.caretAt(local * _factor(page))));
  }

  void _scrollTick() {
    final point = _viewportPoint;
    if (point == null) return;
    final size = viewportSize();
    double axis(double v, double extent) {
      if (v < edge) return -math.min(24.0, (edge - v) * 0.5 + 2);
      if (v > extent - edge) return math.min(24.0, (v - (extent - edge)) * 0.5 + 2);
      return 0;
    }

    final delta = Offset(axis(point.dx, size.width), axis(point.dy, size.height));
    if (delta == Offset.zero) return;
    scrollBy(delta);
    _extend();
  }

  /// Selects the word or line under [local] on [page] without a drag, for a
  /// long-press or a right click on unselected text.
  Future<PdfTextLayer?> selectWordAt(int page, Offset local) async {
    final layer = await selection.loadLayer(page);
    if (layer == null || layer.isEmpty) return null;
    final point = local * _factor(page);
    if (!layer.isOverText(point, slop: 6)) return null;
    final index = layer.charAt(point);
    if (index == null) return null;
    final (start, end) = layer.wordAt(index);
    selection.select(PdfCaret(page, start), PdfCaret(page, end));
    return layer;
  }

  /// Stops any scrolling under way.
  void dispose() {
    _scroller?.cancel();
    overText.dispose();
  }
}
