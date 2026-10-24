import 'dart:ui' as ui;

import '../common/reader_contract.dart';
import '../engines/pdfium/pdf_engine.dart';
import 'thumbnail_renderer.dart';

/// A PDF page, whole, as PDFium draws it: the saved `page_number`, else
/// page 1. A password-protected or damaged file fails to open and gets no
/// thumbnail.
class PdfThumbnailRenderer implements ThumbnailRenderer {
  const PdfThumbnailRenderer();

  @override
  Future<ui.Image?> render(String path, {required int width, ReadingPosition? position}) async {
    final document = await PdfiumDocument.openFile(path);
    try {
      if (document.pageCount == 0) return null;
      var index = (positionIndex(position, PositionKeys.pageNumber) ?? 1) - 1;
      if (index < 0 || index >= document.pageCount || document.pageSizes[index].width <= 0) index = 0;
      if (document.pageSizes[index].width <= 0) return null;
      final page = await document.renderThumbnail(index, width: width);
      return await page.toImage();
    } finally {
      await document.close();
    }
  }
}
