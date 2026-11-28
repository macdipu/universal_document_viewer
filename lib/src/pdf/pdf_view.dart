import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_math/vector_math_64.dart' show Quad;

import '../common/document_viewer_theme.dart';
import '../common/document_viewer_strings.dart';
import '../common/reader_contract.dart';
import '../engines/pdfium/pdf_engine.dart' show PdfRenderTask, PdfiumDocument;
import '../engines/pdfium/pdf_types.dart';
import 'pdf_controller.dart';
import 'pdf_image_cache.dart';
import 'pdf_layout.dart';
import 'pdf_selection.dart';
import 'pdf_selection_gestures.dart';

/// Extra items for the menu that opens over selected text, after Copy and
/// Select all: highlight, bookmark, look up. [controller] has the selection
/// ([PdfController.selectedText]).
typedef PdfSelectionMenuItems = List<ContextMenuButtonItem> Function(BuildContext context, PdfController controller);

/// Shows the PDF a [PdfController] has opened, in its layout.
///
/// Pages are built only near the viewport, each as a low-resolution image
/// sharpened with tiles when zoomed in. Pinch, double-tap or the mouse wheel
/// zoom. Search matches are highlighted, the current one apart from the
/// rest. Links to pages jump; web links open outside the app (`http`,
/// `https` and `mailto` only).
///
/// Text can be selected where the page has any: drag with the mouse (double
/// click for a word, triple for a line; Ctrl or Cmd+C copies, +A selects
/// all, right click opens a menu). The selection is the controller's
/// ([PdfController.selectedText], [PdfController.copySelection]).
/// What [PdfView.pageOverlayBuilder] is: builds the overlay for zero-based page [page], whose size in PDF
/// points is [pageSize]; null for none.
typedef PdfPageOverlayBuilder = Widget? Function(BuildContext context, int page, Size pageSize);

class PdfView extends StatefulWidget {
  /// Shows [controller]'s document.
  const PdfView({
    super.key,
    required this.controller,
    this.backgroundColor,
    this.onTap,
    this.errorBuilder,
    this.showScrollbar = false,
    this.selectionMenuItems,
    this.pageOverlayBuilder,
  });

  /// The document to show; load it with [PdfController.loadFile] or
  /// [PdfController.loadBytes].
  final PdfController controller;

  /// Behind and between the pages. Defaults to the theme's surface colour.
  final Color? backgroundColor;

  /// A tap on a page (not on a link); return true if it was handled.
  final bool Function()? onTap;

  /// Shown instead of the document when it fails to open. Defaults to a
  /// short message.
  final Widget Function(BuildContext context, DocumentLoadError error)? errorBuilder;

  /// Shows a draggable vertical scrollbar in its own gutter at the right edge.
  /// Meant for mouse-driven desktops; leave it off where touch scrolling is
  /// the norm. Only applies to the vertical (continuous) layout.
  final bool showScrollbar;

  /// More items for the selection menu, after Copy and Select all.
  final PdfSelectionMenuItems? selectionMenuItems;

  /// Builds something to draw over a page, or null for nothing. The widget fills the page's own box, so it
  /// stays on the page as the page scrolls and zooms; [pageSize] is the page's size in PDF points, for
  /// placing things by their position on the page (a fraction of it is a fraction of the box). It is built
  /// for each page that is on screen, never takes touches, and may listen to anything it needs to change
  /// itself (a scan, a stamp, a highlight the app keeps).
  final PdfPageOverlayBuilder? pageOverlayBuilder;

  @override
  State<PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<PdfView> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  PdfImageCache? _cache;
  PdfLayout? _layout;
  Object? _layoutKey;
  int _rotationSeen = 0;
  bool _positioned = false;
  bool _updateScheduled = false;

  /// Tiles to paint per page at the current zoom level.
  var _tilesByPage = <int, List<PdfTileKey>>{};
  var _tileLevel = 1;

  /// Links per page, loaded on first tap.
  final _links = <int, List<PdfLink>>{};

  Offset? _doubleTapAt;

  final _focus = FocusNode(debugLabel: 'PdfView');
  final _viewKey = GlobalKey();
  late PdfSelectionGestures _gestures = _makeGestures();

  PdfSelectionGestures _makeGestures() => PdfSelectionGestures(
    selection: controller.selection,
    layout: () => _layout,
    pageSize: (page) => controller.document!.pageSizes[page],
    contentAt: (point) => _visibleRect().topLeft + point / _scale,
    scrollBy: (delta) {
      _snap.stop();
      _setTransform(_scale, _visibleRect().topLeft + delta / _scale);
    },
    viewportSize: () => _layout?.viewport ?? Size.zero,
  );

  /// Where the selection menu is open, in this view's coordinates; null
  /// when it is closed.
  TextSelectionToolbarAnchors? _menu;

  /// Whether the selection was made by touch, so it shows drag handles.
  bool _touchSelecting = false;

  /// Settles a horizontal swipe on a whole page.
  late final _snap = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(_onSnapTick);
  Matrix4Tween? _snapTween;

  PdfController get controller => widget.controller;

  static const _maxZoom = 8.0;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChanged);
    _transform.addListener(_scheduleUpdate);
    controller.attachView(
      zoom: () => _transform.value.getMaxScaleOnAxis(),
      setZoom: _setZoom,
      jumpToPage: _jumpToPage,
      showMatch: _showMatch,
    );
    // The controller may have opened the document before this view was
    // built: set up for it now, as a change notice would.
    _onControllerChanged();
  }

  @override
  void didUpdateWidget(PdfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller
        ..removeListener(_onControllerChanged)
        ..detachView();
      controller.addListener(_onControllerChanged);
      controller.attachView(
        zoom: () => _transform.value.getMaxScaleOnAxis(),
        setZoom: _setZoom,
        jumpToPage: _jumpToPage,
        showMatch: _showMatch,
      );
      _gestures.dispose();
      _gestures = _makeGestures();
      _menu = null;
      // The old controller's images and links don't belong to this one.
      _onControllerChanged();
    }
  }

  @override
  void dispose() {
    controller
      ..removeListener(_onControllerChanged)
      ..detachView();
    _snap.dispose();
    _transform.dispose();
    _cache?.dispose();
    _gestures.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final document = controller.document;
    // Pages turned: every image and link box read so far is for the old orientation.
    if (_cache?.document != document || _rotationSeen != controller.rotation) {
      _rotationSeen = controller.rotation;
      _cache?.dispose();
      _cache = document == null ? null : PdfImageCache(document);
      _links.clear();
    }
    if (mounted) setState(() {});
  }

  // --- Geometry ----------------------------------------------------------

  double get _scale => _transform.value.getMaxScaleOnAxis();

  /// The part of the content on screen.
  Rect _visibleRect() {
    final layout = _layout;
    if (layout == null) return Rect.zero;
    final matrix = _transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    return Rect.fromLTWH(
      -translation.x / scale,
      -translation.y / scale,
      layout.viewport.width / scale,
      layout.viewport.height / scale,
    );
  }

  /// Sets scale and the content point at the top-left of the view, kept
  /// within the content.
  void _setTransform(double scale, Offset topLeft) {
    final layout = _layout;
    if (layout == null) return;
    final s = scale.clamp(1.0, _maxZoom);
    final maxX = math.max(0.0, layout.size.width - layout.viewport.width / s);
    final maxY = math.max(0.0, layout.size.height - layout.viewport.height / s);
    final x = topLeft.dx.clamp(0.0, maxX);
    final y = topLeft.dy.clamp(0.0, maxY);
    _transform.value = Matrix4.identity()
      ..translateByDouble(-x * s, -y * s, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  /// The spot being read in [layout] (the one in use): the current page and
  /// where the view's top-left sits on it, as fractions of its size.
  (int, Offset)? _anchorIn(PdfLayout layout) {
    if (layout.pages.isEmpty) return null;
    final visible = _visibleRect();
    final page = layout.currentPage(visible, previous: controller.currentPage - 1);
    final rect = layout.pages[page];
    return (page, Offset((visible.left - rect.left) / rect.width, (visible.top - rect.top) / rect.height));
  }

  void _setZoom(double zoom, {Offset? focus}) {
    final layout = _layout;
    if (layout == null) return;
    final visible = _visibleRect();
    final point = focus ?? visible.center;
    final s = zoom.clamp(1.0, _maxZoom);
    // Keep [point] where it is on screen.
    final screen = (point - visible.topLeft) * _scale;
    _setTransform(s, point - screen / s);
  }

  void _onSnapTick() {
    final tween = _snapTween;
    if (tween != null) _transform.value = tween.evaluate(CurvedAnimation(parent: _snap, curve: Curves.easeOut));
  }

  /// Horizontal layout at page width: a swipe ends on a whole page - the
  /// next or previous one for a flick, the nearest one for a slow drag.
  void _onInteractionEnd(ScaleEndDetails details) {
    final layout = _layout;
    if (layout == null || !layout.isHorizontal || _scale > 1.01 || layout.pages.isEmpty) return;
    final visible = _visibleRect();
    var page = layout.currentPage(visible, previous: controller.currentPage - 1);
    final velocity = details.velocity.pixelsPerSecond.dx;
    final start = layout.pages[page].left - PdfLayout.margin;
    if (velocity < -300 && visible.left >= start - 1) page += 1;
    if (velocity > 300 && visible.left <= start + 1) page -= 1;
    page = page.clamp(0, layout.pages.length - 1);
    final maxX = math.max(0.0, layout.size.width - layout.viewport.width);
    final x = (layout.pages[page].left - PdfLayout.margin).clamp(0.0, maxX);
    final target = Matrix4.identity()..translateByDouble(-x, -visible.top, 0, 1);
    _snapTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
    _snap.forward(from: 0);
  }

  void _jumpToPage(int page) {
    final layout = _layout;
    if (layout == null || page < 0 || page >= layout.pages.length) return;
    final rect = layout.pages[page];
    final visible = _visibleRect();
    _setTransform(
      _scale,
      layout.isHorizontal
          ? Offset(rect.left - PdfLayout.margin, visible.top)
          : Offset(visible.left, rect.top - PdfLayout.margin),
    );
  }

  /// Scrolls a search hit into view (centred) if it isn't already.
  void _showMatch(PdfTextMatch match) {
    final layout = _layout;
    final document = controller.document;
    if (layout == null || document == null || match.page >= layout.pages.length) return;
    final page = layout.pages[match.page];
    final factor = page.width / document.pageSizes[match.page].width;
    final hit = match.bounds;
    final bounds = match.rects.isEmpty
        ? page
        : Rect.fromLTRB(
            page.left + hit.left * factor,
            page.top + hit.top * factor,
            page.left + hit.right * factor,
            page.top + hit.bottom * factor,
          );
    final visible = _visibleRect();
    if (visible.deflate(8).contains(bounds.topLeft) && visible.deflate(8).contains(bounds.bottomRight)) return;
    _setTransform(_scale, bounds.center - Offset(visible.width / 2, visible.height / 2));
  }

  // --- Reacting to the viewport ------------------------------------------

  void _scheduleUpdate() {
    if (_updateScheduled) return;
    _updateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScheduled = false;
      if (!mounted) return;
      _update();
      // After the frame: the transform can change during layout.
      controller.onZoomChanged();
    });
  }

  /// Works out the page being read and what to render, after the view
  /// moved or zoomed. Never called from paint.
  void _update() {
    final layout = _layout;
    final cache = _cache;
    final document = controller.document;
    if (layout == null || cache == null || document == null || layout.pages.isEmpty) return;
    final visible = _visibleRect();
    final page = layout.currentPage(visible, previous: controller.currentPage - 1);
    controller.onPageChanged(page + 1);

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scale = _scale;
    final onScreen = layout.pagesIn(visible).toSet();
    // One page either side, at prefetch priority.
    final around = <int>{
      for (final p in onScreen) ...[p - 1, p, p + 1],
    }.where((p) => p >= 0 && p < layout.pages.length);

    // Past 1.25x, the base image is too soft: tiles at the next power of
    // two (2x, 4x, 8x).
    final level = scale <= 1.25 ? 1 : math.min(8, math.pow(2, (math.log(scale) / math.ln2).ceil()).toInt());
    final tiles = <int, List<PdfTileKey>>{};
    if (level > 1) {
      for (final p in onScreen) {
        final rect = layout.pages[p];
        final part = rect.intersect(visible);
        if (part.isEmpty) continue;
        final pixels = level * dpr;
        final local = part.shift(-rect.topLeft);
        final step = PdfImageCache.tileSize / pixels;
        final keys = <PdfTileKey>[];
        for (var row = (local.top / step).floor(); row * step < local.bottom; row++) {
          for (var column = (local.left / step).floor(); column * step < local.right; column++) {
            keys.add((page: p, level: level, column: column, row: row));
          }
        }
        tiles[p] = keys;
      }
    }
    final tilesChanged = level != _tileLevel || !_sameTiles(tiles, _tilesByPage);
    _tileLevel = level;
    _tilesByPage = tiles;
    cache.request(
      basePages: around,
      visiblePages: onScreen,
      baseWidth: (p) => PdfImageCache.baseWidthFor(layout.pages[p].width * dpr),
      tiles: tiles.values.expand((t) => t),
      tileFullSize: (key) {
        final rect = layout.pages[key.page];
        return Size(rect.width * key.level * dpr, rect.height * key.level * dpr);
      },
    );
    if (tilesChanged) setState(() {});
  }

  static bool _sameTiles(Map<int, List<PdfTileKey>> a, Map<int, List<PdfTileKey>> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      for (var i = 0; i < other.length; i++) {
        if (other[i] != entry.value[i]) return false;
      }
    }
    return true;
  }

  // --- Taps and the wheel --------------------------------------------------

  Future<void> _onPageTap(int page, Offset local) async {
    final document = controller.document;
    final layout = _layout;
    if (document == null || layout == null) return;
    final factor = document.pageSizes[page].width / layout.pages[page].width;
    final point = local * factor;
    final links = _links[page] ??= await document.links(page).catchError((Object _) => <PdfLink>[]);
    for (final link in links) {
      if (!link.rects.any((r) => r.inflate(2).contains(point))) continue;
      if (link.page != null) {
        _jumpToPage(link.page!);
        return;
      }
      final uri = link.url == null ? null : Uri.tryParse(link.url!);
      if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    widget.onTap?.call();
  }

  /// Mouse-and-touchpad platforms, where pinch-to-zoom comes from a touchpad
  /// gesture (handled here) rather than from touch, and where the zoom
  /// buttons, Ctrl + wheel and double-click also work.
  bool _mouseDriven(BuildContext context) => switch (Theme.of(context).platform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };

  double _trackpadLastScale = 1;
  bool _trackpadPinching = false;

  void _onTrackpadStart(PointerPanZoomStartEvent event) {
    _trackpadLastScale = 1;
    _trackpadPinching = false;
  }

  /// Panning is InteractiveViewer's (its scale is off on these platforms); only a
  /// deliberate pinch, past the noise a plain two-finger scroll carries, zooms.
  void _onTrackpadUpdate(PointerPanZoomUpdateEvent event) {
    if (!_mouseDriven(context)) return;
    if (!_trackpadPinching && (event.scale - 1).abs() < 0.06) return;
    _trackpadPinching = true;
    final ratio = event.scale / _trackpadLastScale;
    _trackpadLastScale = event.scale;
    final visible = _visibleRect();
    _setZoom(_scale * ratio, focus: visible.topLeft + event.localPosition / _scale);
  }

  /// The scrollbar gutter, drawn beside the pages (never over them).
  Widget _scrollbarGutter() {
    return SizedBox(
      width: _PdfScrollbar.gutter,
      child: ValueListenableBuilder<Matrix4>(
        valueListenable: _transform,
        builder: (context, _, _) {
          final layout = _layout;
          if (layout == null || layout.isHorizontal) return const SizedBox.shrink();
          final visible = _visibleRect();
          return _PdfScrollbar(
            contentHeight: layout.size.height,
            visibleTop: visible.top,
            visibleHeight: visible.height,
            onScrollTo: (top) {
              _snap.stop();
              final now = _visibleRect();
              _setTransform(_scale, Offset(now.left, top));
            },
          );
        },
      ),
    );
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scroll = event as PointerScrollEvent;
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed || keys.isMetaPressed) {
        final visible = _visibleRect();
        final focus = visible.topLeft + scroll.localPosition / _scale;
        _setZoom(_scale * (scroll.scrollDelta.dy > 0 ? 0.9 : 1.1), focus: focus);
      } else {
        final visible = _visibleRect();
        _setTransform(_scale, visible.topLeft + scroll.scrollDelta / _scale);
      }
    });
  }

  // --- Selection -----------------------------------------------------------

  Color _selectionColor(BuildContext context) =>
      DefaultSelectionStyle.of(context).selectionColor ?? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3);

  Offset _viewLocal(Offset global) => (_viewKey.currentContext!.findRenderObject()! as RenderBox).globalToLocal(global);

  void _onPrimaryDown(int page, Offset local) {
    _focus.requestFocus();
    _touchSelecting = false;
    _hideMenu();
    unawaited(_gestures.pointerDown(page, local));
  }

  void _onDragStart(Offset global) => _gestures.dragStart(_viewLocal(global));

  void _onDragUpdate(Offset global) => _gestures.dragUpdate(_viewLocal(global));

  Future<void> _onLongPress(int page, Offset local) async {
    _focus.requestFocus();
    _hideMenu();
    final layer = await _gestures.selectWordAt(page, local);
    if (layer == null || !mounted) return;
    unawaited(HapticFeedback.selectionClick());
    // Holding on and dragging goes on to extend the word.
    _gestures.beginDragFrom(controller.selection.anchor!);
    setState(() => _touchSelecting = true);
  }

  void _onLongPressMove(Offset global) => _gestures.dragUpdate(_viewLocal(global));

  void _onLongPressEnd() {
    _gestures.dragEnd();
    _showTouchMenu();
  }

  /// The ends of the selection as rectangles in this view's coordinates;
  /// null when it isn't on screen or its text isn't read yet.
  (Rect, Rect)? _edgeRects() {
    final selection = controller.selection;
    final from = selection.start;
    final to = selection.endCaret;
    final layout = _layout;
    final document = controller.document;
    if (from == null || to == null || layout == null || document == null) return null;
    final visible = _visibleRect();
    Rect? rectOf(int pageIndex, bool first) {
      final layer = selection.layerOf(pageIndex);
      final range = selection.rangeOn(pageIndex);
      if (layer == null || range == null || pageIndex >= layout.pages.length) return null;
      final rects = first ? layer.rects(range.$1, range.$1 + 1) : layer.rects(range.$2 - 1, range.$2);
      if (rects.isEmpty) return null;
      final page = layout.pages[pageIndex];
      final factor = document.pageSizes[pageIndex].width / page.width;
      final r = first ? rects.first : rects.last;
      final content = Rect.fromLTRB(
        page.left + r.left / factor,
        page.top + r.top / factor,
        page.left + r.right / factor,
        page.top + r.bottom / factor,
      );
      return Rect.fromPoints(
        (content.topLeft - visible.topLeft) * _scale,
        (content.bottomRight - visible.topLeft) * _scale,
      );
    }

    final start = rectOf(from.page, true);
    final end = rectOf(to.page, false);
    return start == null || end == null ? null : (start, end);
  }

  void _showTouchMenu() {
    final edges = _edgeRects();
    if (edges == null || !mounted || !controller.selection.hasSelection) return;
    final (start, end) = edges;
    final size = _layout?.viewport ?? Size.zero;
    final x = ((start.left + end.right) / 2).clamp(0.0, size.width);
    setState(() {
      _menu = TextSelectionToolbarAnchors(
        primaryAnchor: Offset(x, start.top - 8),
        secondaryAnchor: Offset(x, end.bottom + 8),
      );
    });
  }

  /// The two draggable handles at the ends of a touch selection.
  Widget _handles(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller.selection, _transform]),
      builder: (context, _) {
        final edges = _touchSelecting && controller.selection.hasSelection ? _edgeRects() : null;
        if (edges == null) return const SizedBox.shrink();
        final strings = DocumentViewerStrings.of(context);
        final size = _layout?.viewport ?? Size.zero;
        final color = Theme.of(context).colorScheme.primary;
        Widget handle(Offset tip, {required bool isStart}) {
          if (tip.dx < -24 || tip.dy < -24 || tip.dx > size.width + 24 || tip.dy > size.height + 24) {
            return const SizedBox.shrink();
          }
          return Positioned(
            left: tip.dx - 24,
            top: tip.dy - 4,
            width: 48,
            height: 48,
            child: Semantics(
              label: isStart ? strings.selectionStartHandle : strings.selectionEndHandle,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (details) => _onHandleStart(isStart, details.globalPosition),
                onPanUpdate: (details) => _gestures.dragUpdate(_viewLocal(details.globalPosition) - _handleGrab),
                onPanEnd: (_) => _onHandleEnd(),
                onPanCancel: _onHandleEnd,
                child: CustomPaint(painter: _HandlePainter(color)),
              ),
            ),
          );
        }

        return Stack(
          children: [handle(edges.$1.bottomLeft, isStart: true), handle(edges.$2.bottomRight, isStart: false)],
        );
      },
    );
  }

  /// A finger on a handle sits below the line it moves; aim above it.
  static const _handleGrab = Offset(0, 28);

  void _onHandleStart(bool isStart, Offset global) {
    final selection = controller.selection;
    final fixed = isStart ? selection.endCaret : selection.start;
    if (fixed == null) return;
    _hideMenu();
    _gestures.beginDragFrom(fixed);
    _gestures.dragStart(_viewLocal(global) - _handleGrab);
  }

  void _onHandleEnd() {
    _gestures.dragEnd();
    _showTouchMenu();
  }

  Future<void> _onSecondaryTap(int page, Offset local, Offset global) async {
    _focus.requestFocus();
    final selection = controller.selection;
    // A right click on unselected text selects the word under it first, as
    // browsers do.
    final range = selection.rangeOn(page);
    final layer = selection.layerOf(page);
    final factor = controller.document!.pageSizes[page].width / _layout!.pages[page].width;
    final inside = range != null && layer != null && _rangeContains(layer.charAt(local * factor), range);
    if (!inside) await _gestures.selectWordAt(page, local);
    if (!mounted) return;
    setState(() => _menu = TextSelectionToolbarAnchors(primaryAnchor: _viewLocal(global)));
  }

  static bool _rangeContains(int? index, (int, int) range) => index != null && index >= range.$1 && index < range.$2;

  void _hideMenu() {
    if (_menu != null) setState(() => _menu = null);
  }

  Future<void> _copy() async {
    final strings = DocumentViewerStrings.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await controller.copySelection();
    if (!ok && !controller.hasSelection.value) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(ok ? strings.copiedText : strings.couldNotCopy)));
  }

  /// The menu over the selection: Copy, Select all, then the app's items.
  Widget _selectionMenu(BuildContext context) {
    final strings = DocumentViewerStrings.of(context);
    final items = <ContextMenuButtonItem>[
      if (controller.hasSelection.value)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          label: strings.copy,
          onPressed: () {
            _hideMenu();
            unawaited(_copy());
          },
        ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        label: strings.selectAll,
        onPressed: () {
          _hideMenu();
          controller.selectAll();
        },
      ),
      ...?widget.selectionMenuItems?.call(context, controller),
    ];
    return TapRegion(
      onTapOutside: (_) => _hideMenu(),
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: _menu!,
        buttonItems: [
          for (final item in items)
            ContextMenuButtonItem(
              type: item.type,
              label: item.label,
              onPressed: item.onPressed == null
                  ? null
                  : () {
                      _hideMenu();
                      item.onPressed!();
                    },
            ),
        ],
      ),
    );
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final background = widget.backgroundColor ?? Theme.of(context).colorScheme.surface;
    if (controller.error case final error?) {
      return ColoredBox(
        color: background,
        child:
            widget.errorBuilder?.call(context, error) ??
            Center(child: Text(DocumentViewerStrings.of(context).loadError(error), textAlign: TextAlign.center)),
      );
    }
    final document = controller.document;
    final cache = _cache;
    if (document == null || cache == null) {
      return ColoredBox(
        color: background,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final gutter = widget.showScrollbar;
    return ColoredBox(
      color: background,
      child: Actions(
        actions: {
          CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
            onInvoke: (_) {
              unawaited(_copy());
              return null;
            },
          ),
          SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
            onInvoke: (_) {
              controller.selectAll();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape &&
                controller.selection.hasSelection) {
              controller.clearSelection();
              _hideMenu();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Stack(
            children: [
              Positioned.fill(child: _pages(context, document, cache, gutter)),
              Positioned.fill(child: _handles(context)),
              if (_menu != null) Positioned.fill(child: _selectionMenu(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pages(BuildContext context, PdfiumDocument document, PdfImageCache cache, bool gutter) {
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            key: _viewKey,
            builder: (context, constraints) {
              final viewport = constraints.biggest;
              final key = (viewport, controller.viewMode, document, controller.rotation);
              if (key != _layoutKey) {
                final previous = _layoutKey as (Size, PdfViewMode, Object, int)?;
                final restoring = previous == null || previous.$2 != controller.viewMode || previous.$3 != document;
                final reading = restoring ? controller.initialPageNumber - 1 : controller.currentPage - 1;
                // Only the viewport changed (the keyboard or search bar opened,
                // the window was resized): in continuous mode the reader stays
                // where they were, at the same zoom, rather than being sent back
                // to the top of the page at zoom 1. Pages only change width, so
                // a spot on a page maps across by proportion.
                final oldLayout = _layout;
                final anchor = !restoring && _positioned && oldLayout != null && !oldLayout.isHorizontal
                    ? _anchorIn(oldLayout)
                    : null;
                final scale = _scale;
                final fresh = _layout = PdfLayout(
                  pageSizes: document.pageSizes,
                  viewport: viewport,
                  mode: controller.viewMode,
                );
                _layoutKey = key;
                _positioned = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  // Only the latest layout's positioning applies.
                  if (!mounted || _positioned || !identical(_layout, fresh)) return;
                  _positioned = true;
                  if (anchor != null && anchor.$1 < fresh.pages.length) {
                    final (index, spot) = anchor;
                    final page = fresh.pages[index];
                    _setTransform(scale, Offset(page.left + spot.dx * page.width, page.top + spot.dy * page.height));
                  } else {
                    _transform.value = Matrix4.identity();
                    _jumpToPage(reading);
                  }
                  _scheduleUpdate();
                  // A go-to or zoom asked for before the pages were placed.
                  controller.applyPending();
                });
              }
              final layout = _layout!;
              // A precision touchpad reports a two-finger scroll as a pan-zoom gesture with a
              // little scale noise; InteractiveViewer reads any scale != 1 as a pinch, so a plain
              // scroll also zoomed. On mouse-and-touchpad platforms the scale is switched off
              // there and deliberate pinches are handled in _onTrackpadUpdate instead.
              return Listener(
                onPointerPanZoomStart: _onTrackpadStart,
                onPointerPanZoomUpdate: _onTrackpadUpdate,
                child: GestureDetector(
                  onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
                  onDoubleTap: () {
                    // A double click that selected a word is not a zoom.
                    if (_gestures.suppressZoom) {
                      _gestures.suppressZoom = false;
                      return;
                    }
                    final visible = _visibleRect();
                    final focus = visible.topLeft + (_doubleTapAt ?? viewport.center(Offset.zero)) / _scale;
                    _setZoom(_scale > 1.1 ? 1 : 2.5, focus: focus);
                  },
                  child: InteractiveViewer.builder(
                    transformationController: _transform,
                    minScale: 1,
                    maxScale: _maxZoom,
                    scaleEnabled: !_mouseDriven(context),
                    boundaryMargin: EdgeInsets.zero,
                    // Horizontal pages snap instead of gliding on.
                    interactionEndFrictionCoefficient: layout.isHorizontal ? 1 : 0.0000135,
                    onInteractionStart: (_) {
                      _snap.stop();
                      _hideMenu();
                    },
                    onInteractionEnd: _onInteractionEnd,
                    builder: (context, quad) {
                      final bounds = _quadBounds(quad).inflate(layout.isHorizontal ? viewport.width : viewport.height);
                      return Listener(
                        onPointerSignal: _onWheel,
                        child: SizedBox.fromSize(
                          size: layout.size,
                          child: Stack(
                            children: [
                              for (final page in layout.pagesIn(bounds))
                                Positioned.fromRect(
                                  rect: layout.pages[page],
                                  child: _PdfPage(
                                    key: ValueKey(page),
                                    page: page,
                                    cache: cache,
                                    search: controller.searchController,
                                    pageSize: document.pageSizes[page],
                                    tiles: _tilesByPage[page] ?? const [],
                                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                                    onTap: (local) => _onPageTap(page, local),
                                    selection: controller.selection,
                                    selectionColor: _selectionColor(context),
                                    gestures: _gestures,
                                    onPrimaryDown: (local) => _onPrimaryDown(page, local),
                                    onDragStart: _onDragStart,
                                    onDragUpdate: _onDragUpdate,
                                    onDragEnd: _gestures.dragEnd,
                                    onLongPress: (local) => _onLongPress(page, local),
                                    onLongPressMove: _onLongPressMove,
                                    onLongPressEnd: _onLongPressEnd,
                                    onSecondaryTap: (local, global) => _onSecondaryTap(page, local, global),
                                    overlay: widget.pageOverlayBuilder,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
        if (gutter) _scrollbarGutter(),
      ],
    );
  }

  static Rect _quadBounds(Quad quad) {
    final xs = [quad.point0.x, quad.point1.x, quad.point2.x, quad.point3.x];
    final ys = [quad.point0.y, quad.point1.y, quad.point2.y, quad.point3.y];
    return Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
  }
}

/// One page: white paper, its base image, any sharper tiles, search
/// highlights and the selection.
class _PdfPage extends StatelessWidget {
  const _PdfPage({
    super.key,
    required this.page,
    required this.cache,
    required this.search,
    required this.pageSize,
    required this.tiles,
    required this.devicePixelRatio,
    required this.onTap,
    required this.selection,
    required this.selectionColor,
    required this.gestures,
    required this.onPrimaryDown,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onSecondaryTap,
    required this.onLongPress,
    required this.onLongPressMove,
    required this.onLongPressEnd,
    this.overlay,
  });

  final PdfPageOverlayBuilder? overlay;
  final int page;
  final PdfImageCache cache;
  final PdfSearchController search;
  final Size pageSize;
  final List<PdfTileKey> tiles;
  final double devicePixelRatio;
  final void Function(Offset local) onTap;
  final PdfSelectionController selection;
  final Color selectionColor;
  final PdfSelectionGestures gestures;
  final void Function(Offset local) onPrimaryDown;
  final void Function(Offset global) onDragStart;
  final void Function(Offset global) onDragUpdate;
  final VoidCallback onDragEnd;
  final void Function(Offset local, Offset global) onSecondaryTap;
  final void Function(Offset local) onLongPress;
  final void Function(Offset global) onLongPressMove;
  final VoidCallback onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    final highlights = DocumentViewerTheme.of(context);
    final over = overlay?.call(context, page, pageSize);
    final paper = DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))],
      ),
      child: CustomPaint(
        painter: _PagePainter(
          page: page,
          cache: cache,
          search: search,
          selection: selection,
          pageSize: pageSize,
          tiles: tiles,
          devicePixelRatio: devicePixelRatio,
          match: highlights.matchBackground!.withValues(alpha: 0.45),
          current: highlights.currentMatchBackground!.withValues(alpha: 0.75),
          selected: selectionColor,
        ),
        // The app's overlay, inside the page's own box: it moves and zooms with the page and takes no touches.
        child: over == null ? null : IgnorePointer(child: over),
      ),
    );
    return Semantics(
      label: DocumentViewerStrings.of(context).page(page + 1),
      child: ValueListenableBuilder<bool>(
        valueListenable: gestures.overText,
        child: Listener(
          onPointerDown: (event) {
            if (event.kind == PointerDeviceKind.mouse && event.buttons == kPrimaryButton) {
              onPrimaryDown(event.localPosition);
            }
          },
          onPointerHover: (event) => gestures.hover(page, event.localPosition),
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _TextDragRecognizer: GestureRecognizerFactoryWithHandlers<_TextDragRecognizer>(
                () => _TextDragRecognizer(allowed: () => gestures.overText.value),
                (recognizer) => recognizer
                  ..onStart = ((details) => onDragStart(details.globalPosition))
                  ..onUpdate = ((details) => onDragUpdate(details.globalPosition))
                  ..onEnd = ((_) => onDragEnd())
                  ..onCancel = onDragEnd,
              ),
              LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
                ),
                (recognizer) => recognizer
                  ..onLongPressStart = ((details) => onLongPress(details.localPosition))
                  ..onLongPressMoveUpdate = ((details) => onLongPressMove(details.globalPosition))
                  ..onLongPressEnd = ((_) => onLongPressEnd()),
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                if (gestures.suppressClear) {
                  gestures.suppressClear = false;
                } else {
                  selection.clear();
                }
                onTap(details.localPosition);
              },
              onSecondaryTapUp: (details) => onSecondaryTap(details.localPosition, details.globalPosition),
              child: paper,
            ),
          ),
        ),
        builder: (context, overText, child) =>
            MouseRegion(cursor: overText ? SystemMouseCursors.text : MouseCursor.defer, child: child),
      ),
    );
  }
}

/// A selection handle: a dot hanging below the end of the selected text.
class _HandlePainter extends CustomPainter {
  _HandlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, 14);
    canvas.drawCircle(center, 9, Paint()..color = color);
    canvas.drawCircle(
      center,
      9,
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.color != color;
}

/// A mouse drag that starts over text, so selecting wins over panning; over
/// blank paper the drag still pans.
class _TextDragRecognizer extends PanGestureRecognizer {
  _TextDragRecognizer({required this.allowed}) : super(supportedDevices: const {PointerDeviceKind.mouse});

  final bool Function() allowed;

  @override
  bool isPointerAllowed(PointerEvent event) => allowed() && super.isPointerAllowed(event);
}

class _PagePainter extends CustomPainter {
  _PagePainter({
    required this.page,
    required this.cache,
    required this.search,
    required this.selection,
    required this.pageSize,
    required this.tiles,
    required this.devicePixelRatio,
    required this.match,
    required this.current,
    required this.selected,
  }) : super(repaint: Listenable.merge([cache, search, selection]));

  final int page;
  final PdfImageCache cache;
  final PdfSearchController search;
  final Size pageSize;
  final List<PdfTileKey> tiles;
  final double devicePixelRatio;
  final PdfSelectionController selection;
  final Color match;
  final Color current;
  final Color selected;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final base = cache.base(page);
    if (base != null) {
      canvas.drawImageRect(
        base,
        Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
        Offset.zero & size,
        paint,
      );
    }
    for (final key in tiles) {
      final tile = cache.tile(key);
      if (tile == null) continue;
      final step = PdfImageCache.tileSize / (key.level * devicePixelRatio);
      final dst = Rect.fromLTWH(
        key.column * step,
        key.row * step,
        tile.width / (key.level * devicePixelRatio),
        tile.height / (key.level * devicePixelRatio),
      );
      canvas.drawImageRect(tile, Rect.fromLTWH(0, 0, tile.width.toDouble(), tile.height.toDouble()), dst, paint);
    }
    final factor = size.width / pageSize.width;
    final hits = search.matchesOn(page);
    for (final (hit, isCurrent) in hits) {
      final highlight = Paint()..color = isCurrent ? current : match;
      for (final rect in hit.rects) {
        canvas.drawRect(
          Rect.fromLTRB(rect.left * factor, rect.top * factor, rect.right * factor, rect.bottom * factor).inflate(1),
          highlight,
        );
      }
    }
    for (final (rect, color) in selection.highlightRectsOn(page)) {
      canvas.drawRect(
        Rect.fromLTRB(rect.left * factor, rect.top * factor, rect.right * factor, rect.bottom * factor),
        Paint()..color = color.withValues(alpha: 0.35),
      );
    }
    final chosen = selection.rectsOn(page);
    if (chosen.isNotEmpty) {
      final fill = Paint()..color = selected;
      for (final rect in chosen) {
        canvas.drawRect(
          Rect.fromLTRB(rect.left * factor, rect.top * factor, rect.right * factor, rect.bottom * factor),
          fill,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.page != page ||
      old.cache != cache ||
      old.tiles != tiles ||
      old.match != match ||
      old.current != current ||
      old.selected != selected;
}

/// A whole page as a small image (e.g. a thumbnail strip), rendered at
/// low priority.
class PdfPageThumbnail extends StatefulWidget {
  /// A thumbnail of [pageNumber], [width] logical pixels wide.
  const PdfPageThumbnail({super.key, required this.controller, required this.pageNumber, this.width = 70});

  /// The controller whose open document the page comes from.
  final PdfController controller;

  /// 1-based.
  final int pageNumber;

  /// Logical pixels.
  final double width;

  @override
  State<PdfPageThumbnail> createState() => _PdfPageThumbnailState();
}

class _PdfPageThumbnailState extends State<PdfPageThumbnail> {
  ui.Image? _image;
  Object? _requested;
  double _devicePixelRatio = 1;

  /// The render under way. Cancelled when the thumbnail goes away or wants
  /// something else, so a strip scrolled past (or a closing document)
  /// doesn't leave renders queued in the worker.
  PdfRenderTask? _task;

  @override
  void initState() {
    super.initState();
    // Built before the document is open, it renders once it is.
    widget.controller.addListener(_load);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    _load();
  }

  @override
  void didUpdateWidget(PdfPageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_load);
      widget.controller.addListener(_load);
    }
    _load();
  }

  Future<void> _load() async {
    final document = widget.controller.document;
    final width = (widget.width * _devicePixelRatio).round();
    final key = document == null ? null : (document, widget.pageNumber, width);
    if (key == _requested) return;
    _requested = key;
    _task?.cancel();
    _task = null;
    if (document == null) {
      if (_image != null) {
        setState(() {
          _image?.dispose();
          _image = null;
        });
      }
      return;
    }
    final task = _task = document.renderThumbnailTask(widget.pageNumber - 1, width: width);
    try {
      final image = await (await task.result).toImage();
      if (!mounted || !identical(_task, task)) {
        image.dispose();
        return;
      }
      _task = null;
      setState(() {
        _image?.dispose();
        _image = image;
      });
    } catch (_) {
      // Cancelled, or failed: a thumbnail is optional, the slot stays blank.
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_load);
    _task?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return ColoredBox(
      color: Colors.white,
      child: image == null ? const SizedBox.expand() : RawImage(image: image, fit: BoxFit.contain),
    );
  }
}

/// A vertical scrollbar for the PDF view: a track with a draggable thumb that
/// follows the view's position and size. Click the track to jump there.
class _PdfScrollbar extends StatefulWidget {
  const _PdfScrollbar({
    required this.contentHeight,
    required this.visibleTop,
    required this.visibleHeight,
    required this.onScrollTo,
  });

  static const gutter = 14.0;

  /// Height of all the pages, and the part of it on screen, in content pixels.
  final double contentHeight;
  final double visibleTop;
  final double visibleHeight;

  /// Asks the view to put [top] (a content y) at the top of the screen.
  final ValueChanged<double> onScrollTo;

  @override
  State<_PdfScrollbar> createState() => _PdfScrollbarState();
}

class _PdfScrollbarState extends State<_PdfScrollbar> {
  static const _minThumb = 36.0;
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxHeight;
        final scrollable = widget.contentHeight - widget.visibleHeight;
        if (scrollable <= 1 || track <= _minThumb) return const SizedBox.shrink();
        final thumb = math.max(_minThumb, track * widget.visibleHeight / widget.contentHeight).clamp(_minThumb, track);
        final range = track - thumb;
        final fraction = (widget.visibleTop / scrollable).clamp(0.0, 1.0);
        final thumbTop = range * fraction;
        final active = _hover || _dragging;

        double contentTopFor(double thumbTopPx) => (thumbTopPx / range).clamp(0.0, 1.0) * scrollable;

        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Click on the track: centre the thumb there.
            onTapDown: (details) => widget.onScrollTo(contentTopFor(details.localPosition.dy - thumb / 2)),
            onVerticalDragStart: (_) => setState(() => _dragging = true),
            onVerticalDragEnd: (_) => setState(() => _dragging = false),
            onVerticalDragCancel: () => setState(() => _dragging = false),
            // The thumb follows the pointer 1:1 along the track.
            onVerticalDragUpdate: (details) =>
                widget.onScrollTo(widget.visibleTop + details.delta.dy * scrollable / range),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: scheme.onSurface.withValues(alpha: active ? 0.07 : 0.04)),
                ),
                Positioned(
                  top: thumbTop,
                  left: 3,
                  right: 3,
                  height: thumb,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: _dragging ? 0.6 : (active ? 0.5 : 0.36)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
