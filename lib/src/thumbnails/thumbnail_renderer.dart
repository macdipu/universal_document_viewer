import 'dart:ui' as ui;

import '../common/reader_contract.dart';

/// Draws one page of one document format for [DocumentThumbnails]: the
/// page a saved [ReadingPosition] is on, else the first.
///
/// [render] returns an image exactly [width] pixels wide, as tall as the
/// page's aspect ratio makes it, or null when the file has nothing to show.
/// A position that doesn't fit the file (a page past the end, keys of
/// another format) falls back to the first page. It may throw on a damaged
/// file: [DocumentThumbnails] turns any failure into null for its callers.
abstract interface class ThumbnailRenderer {
  Future<ui.Image?> render(String path, {required int width, ReadingPosition? position});
}

/// [position]'s [key] as a non-negative int, or null.
int? positionIndex(ReadingPosition? position, String key) => switch (position?[key]) {
  final int value when value >= 0 => value,
  _ => null,
};
