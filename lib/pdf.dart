/// PDF documents, rendered by PDFium.
///
/// [PdfView] shows a document that a [PdfController] has opened: pages laid
/// out continuously or side by side ([PdfViewMode]), pinch and double-tap
/// zoom, text search and links. [PdfPageThumbnail] draws one page small.
///
/// [PdfiumDocument] is the engine underneath, for apps that render or
/// extract text themselves.
library;

export 'src/engines/pdfium/pdf_engine.dart' show PdfiumDocument, PdfRenderedImage, PdfRenderTask;
export 'src/engines/pdfium/pdf_types.dart';
export 'src/pdf/pdf_controller.dart' hide probePdfTextLayer;
export 'src/pdf/pdf_layout.dart' show PdfViewMode;
export 'src/pdf/pdf_view.dart';
