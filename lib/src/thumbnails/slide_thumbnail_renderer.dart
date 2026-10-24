import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../slides/pptx_parser.dart';
import '../slides/slide_deck_view.dart';
import 'offscreen_render.dart';
import 'thumbnail_renderer.dart';
import 'thumbnail_sources.dart';

/// A slide of a `.pptx` - the saved `slide_index`, else slide 1 - drawn by
/// the reader's own [SlideCard] in the presentation's slide shape (16:9,
/// 4:3, ...).
class SlideThumbnailRenderer implements ThumbnailRenderer {
  const SlideThumbnailRenderer();

  /// The slide's logical width: roomy enough for the card's text sizes to
  /// sit on it as they do in the reader.
  static const double _slideWidth = 560;

  @override
  Future<ui.Image?> render(String path, {required int width, ReadingPosition? position}) async {
    final wanted = positionIndex(position, PositionKeys.slideIndex) ?? 0;
    // Only the wanted slide's XML and pictures are read, in the isolate, and
    // only it crosses back.
    final result = await parseOfficeFile(path, (bytes) => PptxParser.parseSlide(bytes, wanted));
    if (result == null) return null;
    final (:deck, :index) = result;
    if (deck.slides.isEmpty) return null;
    final aspect = (deck.slideHeight / deck.slideWidth).clamp(0.25, 4.0);
    return renderOffscreen(
      SlideCard(slide: deck.slides.first, number: index + 1),
      size: Size(_slideWidth, _slideWidth * aspect),
      width: width,
    );
  }
}
