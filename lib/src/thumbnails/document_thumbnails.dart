import 'dart:typed_data';
import 'dart:ui' as ui;

import '../common/document_format.dart';
import '../common/reader_contract.dart';
import 'pdf_thumbnail_renderer.dart';
import 'sheet_thumbnail_renderer.dart';
import 'slide_thumbnail_renderer.dart';
import 'text_thumbnail_renderer.dart';
import 'thumbnail_renderer.dart';
import 'word_thumbnail_renderer.dart';

/// A small picture of a document's first page, for file lists: PDF page 1,
/// a Word document's first print-layout page, PowerPoint slide 1, the
/// top-left of a spreadsheet's first sheet, or a text file's first lines -
/// each on white, in the page's own shape.
///
/// Given a reader's saved [ReadingPosition], it draws where reading left
/// off instead: that PDF page, the Word print-layout page holding the
/// paragraph at the top, that slide, that sheet scrolled to the saved
/// top-left cell, or the text from the line at the top.
///
/// ```dart
/// final png = await DocumentThumbnails.render(path, width: 160);
/// if (png != null) Image.memory(png);
/// final resumed = await DocumentThumbnails.render(path, width: 160, position: saved);
/// ```
///
/// Parsing runs off the UI isolate where the format allows; drawing needs
/// the widgets binding, so call it from the UI isolate. Caching is the
/// app's business.
abstract final class DocumentThumbnails {
  static const Map<DocumentFormat, ThumbnailRenderer> _renderers = {
    DocumentFormat.pdf: PdfThumbnailRenderer(),
    DocumentFormat.word: WordThumbnailRenderer(),
    DocumentFormat.excel: SheetThumbnailRenderer.xlsx(),
    DocumentFormat.csv: SheetThumbnailRenderer.csv(),
    DocumentFormat.powerpoint: SlideThumbnailRenderer(),
    DocumentFormat.text: TextThumbnailRenderer(),
  };

  /// Widest thumbnail [render] draws.
  static const int maxWidth = 2048;

  /// The first page of the file at [path] - or, with a [position], the
  /// page it's on - as PNG bytes, [width] pixels wide and as tall as the
  /// page's shape makes it. A position that doesn't fit the file gives the
  /// first page. Null - never an error - when there's nothing to show: an
  /// unsupported, missing, damaged, password-protected or too-large file,
  /// or a [width] outside 1-[maxWidth].
  static Future<Uint8List?> render(String path, {required int width, ReadingPosition? position}) async {
    if (width < 1 || width > maxWidth) return null;
    final format = DocumentFormat.fromPath(path);
    final renderer = format == null ? null : _renderers[format];
    if (renderer == null) return null;
    ui.Image? image;
    try {
      image = await renderer.render(path, width: width, position: position);
      final png = await image?.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }
}
