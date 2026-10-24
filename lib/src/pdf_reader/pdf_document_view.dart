import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_math/vector_math_64.dart' show Quad;

import '../engines/pdfium/pdf_engine.dart' show PdfRenderTask;
import '../engines/pdfium/pdf_types.dart';
import 'pdf_document_controller.dart';
import 'pdf_image_cache.dart';
import 'pdf_layout.dart';

/// A PDF file, opened by [controller] and shown in its layout: pages built
/// only near the viewport, pinch/double-tap/wheel zoom, a low-resolution
/// image per page sharpened by tiles when zoomed in, search highlights,
/// and links (web links open outside the app, `http`/`https`/`mailto`
/// only; links to pages jump).
class PdfDocumentView extends StatefulWidget {
  const PdfDocumentView({
    super.key,
    required this.path,
    required this.controller,
    this.passwordProvider,
    this.backgroundColor,
    this.onTap,
    this.errorBuilder,
  });

  final String path;
  final PdfDocumentController controller;

  /// Asked for a password for an encrypted PDF, once per attempt, until it
  /// returns null (give up) or the password works.
  final PdfPasswordProvider? passwordProvider;
  final Color? backgroundColor;

  /// A tap on a page (not on a link); return true if it was handled.
  final bool Function()? onTap;

  /// Shown instead of the document when it fails to open.
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  @override
  State<PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<PdfDocumentView> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  PdfImageCache? _cache;
  PdfLayout? _layout;
  Object? _layoutKey;
  bool _positioned = false;
  bool _updateScheduled = false;

  /// Tiles to paint per page at the current zoom level.
  var _tilesByPage = <int, List<PdfTileKey>>{};
  var _tileLevel = 1;

  /// Links per page, loaded on first tap.
  final _links = <int, List<PdfLink>>{};

  Offset? _doubleTapAt;

  /// Settles a horizontal swipe on a whole page.
  late final _snap = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(_onSnapTick);
  Matrix4Tween? _snapTween;

  PdfDocumentController get controller => widget.controller;

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
    controller.open(widget.path, passwordProvider: widget.passwordProvider);
  }

  @override
  void didUpdateWidget(PdfDocumentView oldWidget) {
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
      // The old controller's images and links don't belong to this one.
      _onControllerChanged();
    }
    // A new controller or file has to be opened, or the view would wait on
    // it forever. (Opening what's already open, or opening, is a no-op.)
    if (oldWidget.controller != controller || oldWidget.path != widget.path) {
      controller.open(widget.path, passwordProvider: widget.passwordProvider);
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
    super.dispose();
  }

  void _onControllerChanged() {
    final document = controller.document;
    if (_cache?.document != document) {
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
        : Rect.fromLTRB(page.left + hit.left * factor, page.top + hit.top * factor, page.left + hit.right * factor,
            page.top + hit.bottom * factor);
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
      if (mounted) _update();
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

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final background = widget.backgroundColor ?? Theme.of(context).colorScheme.surface;
    if (controller.error case final error?) {
      return ColoredBox(
        color: background,
        child: widget.errorBuilder?.call(context, error) ?? const Center(child: Text('This PDF could not be opened.')),
      );
    }
    final document = controller.document;
    final cache = _cache;
    if (document == null || cache == null) {
      return ColoredBox(color: background, child: const Center(child: CircularProgressIndicator()));
    }
    return ColoredBox(
      color: background,
      child: LayoutBuilder(builder: (context, constraints) {
        final viewport = constraints.biggest;
        final key = (viewport, controller.viewMode, document);
        if (key != _layoutKey) {
          final previous = _layoutKey as (Size, PdfReaderViewMode, Object)?;
          final restoring = previous == null || previous.$2 != controller.viewMode || previous.$3 != document;
          final reading = restoring ? controller.initialPageNumber - 1 : controller.currentPage - 1;
          // Only the viewport changed (the keyboard or search bar opened,
          // the window was resized): in continuous mode the reader stays
          // where they were, at the same zoom, rather than being sent back
          // to the top of the page at zoom 1. Pages only change width, so
          // a spot on a page maps across by proportion.
          final oldLayout = _layout;
          final anchor =
              !restoring && _positioned && oldLayout != null && !oldLayout.isHorizontal ? _anchorIn(oldLayout) : null;
          final scale = _scale;
          final fresh =
              _layout = PdfLayout(pageSizes: document.pageSizes, viewport: viewport, mode: controller.viewMode);
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
          });
        }
        final layout = _layout!;
        return GestureDetector(
          onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
          onDoubleTap: () {
            final visible = _visibleRect();
            final focus = visible.topLeft + (_doubleTapAt ?? viewport.center(Offset.zero)) / _scale;
            _setZoom(_scale > 1.1 ? 1 : 2.5, focus: focus);
          },
          child: InteractiveViewer.builder(
            transformationController: _transform,
            minScale: 1,
            maxScale: _maxZoom,
            boundaryMargin: EdgeInsets.zero,
            // Horizontal pages snap instead of gliding on.
            interactionEndFrictionCoefficient: layout.isHorizontal ? 1 : 0.0000135,
            onInteractionStart: (_) => _snap.stop(),
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
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      }),
    );
  }

  static Rect _quadBounds(Quad quad) {
    final xs = [quad.point0.x, quad.point1.x, quad.point2.x, quad.point3.x];
    final ys = [quad.point0.y, quad.point1.y, quad.point2.y, quad.point3.y];
    return Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
  }
}

/// One page: white paper, its base image, any sharper tiles, and search
/// highlights.
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
  });

  final int page;
  final PdfImageCache cache;
  final PdfSearchController search;
  final Size pageSize;
  final List<PdfTileKey> tiles;
  final double devicePixelRatio;
  final void Function(Offset local) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Page ${page + 1}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => onTap(details.localPosition),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))],
          ),
          child: CustomPaint(
            painter: _PagePainter(
              page: page,
              cache: cache,
              search: search,
              pageSize: pageSize,
              tiles: tiles,
              devicePixelRatio: devicePixelRatio,
              match: scheme.secondaryContainer.withValues(alpha: 0.45),
              current: scheme.tertiary.withValues(alpha: 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

class _PagePainter extends CustomPainter {
  _PagePainter({
    required this.page,
    required this.cache,
    required this.search,
    required this.pageSize,
    required this.tiles,
    required this.devicePixelRatio,
    required this.match,
    required this.current,
  }) : super(repaint: Listenable.merge([cache, search]));

  final int page;
  final PdfImageCache cache;
  final PdfSearchController search;
  final Size pageSize;
  final List<PdfTileKey> tiles;
  final double devicePixelRatio;
  final Color match;
  final Color current;

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
    final hits = search.matchesOn(page);
    if (hits.isEmpty) return;
    final factor = size.width / pageSize.width;
    for (final (hit, isCurrent) in hits) {
      final highlight = Paint()..color = isCurrent ? current : match;
      for (final rect in hit.rects) {
        canvas.drawRect(
          Rect.fromLTRB(rect.left * factor, rect.top * factor, rect.right * factor, rect.bottom * factor).inflate(1),
          highlight,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.page != page || old.cache != cache || old.tiles != tiles || old.match != match || old.current != current;
}

/// A whole page as a small image (e.g. a thumbnail strip), rendered at
/// low priority.
class PdfPageThumbnail extends StatefulWidget {
  const PdfPageThumbnail({super.key, required this.controller, required this.pageNumber, this.width = 70});

  final PdfDocumentController controller;

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
