import 'dart:math' as math;
import 'dart:ui';

/// How pages are laid out. A vertical single-page-snap mode isn't offered:
/// [horizontal] already covers reading one page at a time.
enum PdfReaderViewMode { continuous, horizontal }

/// Where each page sits in the viewer's content, at zoom 1.
///
/// - **continuous**: pages stacked top to bottom, each as wide as the
///   viewport (less margins), so zoom 1 is fit-width;
/// - **horizontal**: pages side by side, each fitted inside the viewport.
///
/// Positions are logical pixels in content coordinates; the viewer scales
/// and pans this content.
class PdfLayout {
  PdfLayout({required List<Size> pageSizes, required this.viewport, required this.mode}) {
    var cursor = margin;
    var extent = 0.0;
    for (final size in pageSizes) {
      final aspect = size.width <= 0 || size.height <= 0 ? 612 / 792 : size.width / size.height;
      if (mode == PdfReaderViewMode.continuous) {
        final width = math.max(1.0, viewport.width - 2 * margin);
        final height = width / aspect;
        pages.add(Rect.fromLTWH(margin, cursor, width, height));
        cursor += height + margin;
        extent = math.max(extent, width + 2 * margin);
      } else {
        final box = Size(math.max(1, viewport.width - 2 * margin), math.max(1, viewport.height - 2 * margin));
        final width = math.min(box.width, box.height * aspect);
        final height = width / aspect;
        pages.add(Rect.fromLTWH(cursor, margin + (box.height - height) / 2, width, height));
        cursor += width + margin;
        extent = math.max(extent, height + 2 * margin);
      }
    }
    size = mode == PdfReaderViewMode.continuous
        ? Size(math.max(extent, viewport.width), math.max(cursor, viewport.height))
        : Size(math.max(cursor, viewport.width), math.max(extent, viewport.height));
  }

  static const double margin = 8;

  final Size viewport;
  final PdfReaderViewMode mode;

  /// Each page's rect, in page order.
  final pages = <Rect>[];

  /// The whole content.
  late final Size size;

  bool get isHorizontal => mode == PdfReaderViewMode.horizontal;

  /// Pages whose rect meets [visible] (content coordinates), in order.
  Iterable<int> pagesIn(Rect visible) sync* {
    // Pages are sorted along the scroll axis: find the first, then walk.
    var low = 0;
    var high = pages.length - 1;
    final start = isHorizontal ? visible.left : visible.top;
    while (low < high) {
      final mid = (low + high) >> 1;
      final end = isHorizontal ? pages[mid].right : pages[mid].bottom;
      if (end < start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var i = low; i < pages.length; i++) {
      final page = pages[i];
      if ((isHorizontal ? page.left : page.top) > (isHorizontal ? visible.right : visible.bottom)) break;
      if (page.overlaps(visible)) yield i;
    }
  }

  /// The page at a content point, if any.
  int? pageAt(Offset point) {
    for (final index in pagesIn(Rect.fromCenter(center: point, width: 1, height: 1))) {
      if (pages[index].contains(point)) return index;
    }
    return null;
  }

  /// The page being read in [visible]: the one taking most of the view
  /// along the scroll axis. [previous] stays current while it still fills
  /// at least as much as any other, so the number doesn't flicker between
  /// two half-visible pages.
  int currentPage(Rect visible, {int? previous}) {
    if (pages.isEmpty) return 0;
    var best = previous ?? 0;
    var bestShare = -1.0;
    for (final index in pagesIn(visible)) {
      final page = pages[index];
      final overlap = isHorizontal
          ? math.min(page.right, visible.right) - math.max(page.left, visible.left)
          : math.min(page.bottom, visible.bottom) - math.max(page.top, visible.top);
      final share = overlap / (isHorizontal ? visible.width : visible.height);
      if (share > bestShare + 0.001 || (index == previous && share >= bestShare - 0.001)) {
        best = index;
        bestShare = share;
      }
    }
    return bestShare < 0 ? (previous ?? 0).clamp(0, pages.length - 1) : best;
  }
}
