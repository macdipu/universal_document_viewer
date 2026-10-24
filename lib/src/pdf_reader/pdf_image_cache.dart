import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../engines/pdfium/pdf_engine.dart';
import '../engines/pdfium/pdf_types.dart';

/// A tile of a page rendered at a zoom level: column [column], row [row]
/// of a grid of [PdfImageCache.tileSize]-pixel squares over the page drawn
/// at [level] times its base width.
typedef PdfTileKey = ({int page, int level, int column, int row});

/// Rendered page images for one document: a low-resolution **base** image
/// per page (shown at once, and while zooming) and sharp **tiles** for
/// zoomed-in views, rendered only where visible and reused while panning.
///
/// Requests are made by the view as what's visible changes ([request]),
/// never from paint. Images that arrive notify listeners; images over the
/// byte budget are evicted least-recently-used first (never ones the view
/// currently wants); requests no longer
/// wanted are cancelled while still queued.
class PdfImageCache extends ChangeNotifier {
  PdfImageCache(this.document, {this.maxBytes = 96 << 20});

  final PdfiumDocument document;
  final int maxBytes;

  /// Tile edge in device pixels.
  static const tileSize = 512;

  /// Base images are at most this wide (device pixels).
  static const maxBaseWidth = 2000;

  final _bases = <int, ui.Image>{};
  final _tiles = <PdfTileKey, ui.Image>{};

  /// Most recently used last; keys are page ints (bases) or tile keys.
  final _lru = LinkedHashSet<Object>();
  final _inFlight = <Object, PdfRenderTask>{};

  /// What the last [request] asked for (bases and tiles). Never evicted:
  /// nothing re-requests an image until the view moves, so evicting one of
  /// these would leave its page blank or soft until then.
  var _wanted = <Object>{};
  var _bytes = 0;
  bool _disposed = false;

  ui.Image? base(int page) {
    final image = _bases[page];
    if (image != null) _touch(page);
    return image;
  }

  ui.Image? tile(PdfTileKey key) {
    final image = _tiles[key];
    if (image != null) _touch(key);
    return image;
  }

  /// The base width to render for a page shown [displayWidth] device
  /// pixels wide: rounded up to a 256-pixel step, so small changes in size
  /// don't re-render.
  static int baseWidthFor(double displayWidth) =>
      (((displayWidth / 256).ceil()) * 256).clamp(256, maxBaseWidth);

  /// Asks for what the view needs now: base images for [basePages] at
  /// [baseWidth] device pixels (on-screen pages [visiblePages] first, the
  /// rest as prefetch), and [tiles] (with each tile's full-page pixel size
  /// in [tileFullSize]). Anything queued earlier and not asked for again is
  /// cancelled.
  void request({
    required Iterable<int> basePages,
    required Set<int> visiblePages,
    required int Function(int page) baseWidth,
    Iterable<PdfTileKey> tiles = const [],
    required ui.Size Function(PdfTileKey key) tileFullSize,
  }) {
    if (_disposed) return;
    final wanted = _wanted = <Object>{};
    for (final page in basePages) {
      wanted.add(page);
      final width = baseWidth(page);
      final existing = _bases[page];
      // A base a little smaller than wanted is good enough; tiles cover
      // the zoomed-in case.
      if (existing != null && existing.width >= width * 0.8) continue;
      if (_inFlight.containsKey(page)) continue;
      final size = document.pageSizes[page];
      final height = math.max(1, (width * size.height / size.width).round());
      _start(page, document.render(
        page,
        fullWidth: width,
        fullHeight: height,
        priority: visiblePages.contains(page) ? PdfPriority.visible : PdfPriority.prefetch,
      ), (image) => _bases[page] = image);
    }
    for (final key in tiles) {
      wanted.add(key);
      if (_tiles.containsKey(key) || _inFlight.containsKey(key)) continue;
      final full = tileFullSize(key);
      final region = ui.Rect.fromLTWH(
        key.column * tileSize.toDouble(),
        key.row * tileSize.toDouble(),
        math.min(tileSize.toDouble(), full.width - key.column * tileSize),
        math.min(tileSize.toDouble(), full.height - key.row * tileSize),
      );
      if (region.width <= 0 || region.height <= 0) continue;
      _start(key, document.render(
        key.page,
        fullWidth: full.width.round(),
        fullHeight: full.height.round(),
        region: region,
      ), (image) => _tiles[key] = image);
    }
    for (final key in _inFlight.keys.toList()) {
      if (!wanted.contains(key)) _inFlight.remove(key)?.cancel();
    }
  }

  void _start(Object key, PdfRenderTask task, void Function(ui.Image) store) {
    _inFlight[key] = task;
    task.result.then((rendered) async {
      final ui.Image image;
      try {
        image = await rendered.toImage();
      } catch (_) {
        // Couldn't decode: as if the render failed (asked again once the
        // view moves).
        if (identical(_inFlight[key], task)) _inFlight.remove(key);
        return;
      }
      if (_disposed || !identical(_inFlight[key], task)) {
        image.dispose();
        return;
      }
      _inFlight.remove(key);
      final old = key is int ? _bases[key] : _tiles[key];
      if (old != null) {
        _bytes -= _sizeOf(old);
        old.dispose();
      }
      store(image);
      _bytes += _sizeOf(image);
      _touch(key);
      _evict();
      notifyListeners();
    }, onError: (Object error) {
      if (identical(_inFlight[key], task)) _inFlight.remove(key);
    });
  }

  void _touch(Object key) {
    _lru
      ..remove(key)
      ..add(key);
  }

  static int _sizeOf(ui.Image image) => image.width * image.height * 4;

  /// Least recently used first, skipping what's wanted now: the budget may
  /// be exceeded by what's on screen, never by what isn't.
  void _evict() {
    if (_bytes <= maxBytes) return;
    for (final key in _lru.toList()) {
      if (_bytes <= maxBytes) break;
      if (_wanted.contains(key)) continue;
      _lru.remove(key);
      final image = key is int ? _bases.remove(key) : _tiles.remove(key);
      if (image != null) {
        _bytes -= _sizeOf(image);
        image.dispose();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final task in _inFlight.values) {
      task.cancel();
    }
    _inFlight.clear();
    for (final image in [..._bases.values, ..._tiles.values]) {
      image.dispose();
    }
    _bases.clear();
    _tiles.clear();
    super.dispose();
  }
}
