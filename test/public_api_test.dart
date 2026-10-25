// Compile-time check of every public entry point: each symbol below must be
// exported where a user imports it from. A refactor that drops or moves an
// export fails here, not in someone's app.
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart' as pdf;
import 'package:universal_document_viewer/plain_text.dart' as text;
import 'package:universal_document_viewer/slides.dart' as slides;
import 'package:universal_document_viewer/spreadsheet.dart' as sheet;
import 'package:universal_document_viewer/testing.dart' as testing;
import 'package:universal_document_viewer/universal_document_viewer.dart' as all;
import 'package:universal_document_viewer/word.dart' as word;

void main() {
  test('universal_document_viewer.dart exports the shared API and every format', () {
    expect(<Object>[
      all.DocumentViewer,
      all.DocumentThumbnails,
      all.DocumentController,
      all.DocumentStatus.ready,
      all.DocumentLocation.none,
      all.DocumentSearchState.none,
      all.DocumentViewerStrings,
      all.DocumentViewerStringsScope,
      all.DocumentViewerTheme,
      all.DocumentFormat.pdf,
      all.DocumentLoadError.corrupted,
      all.PositionKeys.pageNumber,
      all.ZipSafetyGuard.maxFileBytes,
      all.decodeTextBytes,
      all.looksLikeBinary,
      all.PdfController,
      all.WordController,
      all.SpreadsheetController,
      all.SlidesController,
      all.PlainTextController,
    ], everyElement(isNotNull));
  });

  test('each format library exports its controller, view, model and the shared contract', () {
    expect(<Object>[
      pdf.PdfController,
      pdf.PdfView,
      pdf.PdfPageThumbnail,
      pdf.PdfViewMode.continuous,
      pdf.PdfiumDocument,
      pdf.PdfOpenException,
      pdf.DocumentController,
      word.WordController,
      word.WordView,
      word.WordPageThumbnail,
      word.WordViewMode.paged,
      word.DocxReader,
      word.WordDocument,
      word.DocumentStatus.ready,
      sheet.SpreadsheetController,
      sheet.SpreadsheetView,
      sheet.XlsxReader,
      sheet.CsvReader,
      sheet.Workbook,
      sheet.CellMatch,
      sheet.DocumentFormat.excel,
      sheet.DocumentLocation.none,
      slides.SlidesController,
      slides.SlidesView,
      slides.SlideCard,
      slides.SlideMatch,
      slides.PptxParser,
      slides.PptxPresentation,
      slides.DocumentSearchState.none,
      text.PlainTextController,
      text.PlainTextView,
      text.TextMatch,
      text.DocumentViewerStrings,
    ], everyElement(isNotNull));
  });

  test('testing.dart exports the document builders', () {
    expect(testing.buildDocx('<w:p/>'), isNotEmpty);
    expect(testing.buildXlsx([const testing.XlsxTestSheet('S', {})]), isNotEmpty);
    expect(testing.buildPptx([testing.titleShape('T')]), isNotEmpty);
  });
}
