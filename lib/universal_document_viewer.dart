/// Open and read PDF, Word (.docx), Excel (.xlsx), CSV, PowerPoint (.pptx)
/// and plain text documents, with the package's own engines.
///
/// The quickest way to show any supported file is [DocumentViewer]:
///
/// ```dart
/// DocumentViewer.file(path)
/// ```
///
/// For your own toolbar, search field or layout, use a format's controller
/// and view: [PdfController] and [PdfView], [WordController] and
/// [WordView], [SpreadsheetController] and [SpreadsheetView],
/// [SlidesController] and [SlidesView], [PlainTextController] and
/// [PlainTextView]. [DocumentThumbnails] draws a preview of any of them.
///
/// This library exports everything. Each format also has a library of its
/// own (`pdf.dart`, `word.dart`, `spreadsheet.dart`, `slides.dart`,
/// `plain_text.dart`) for apps that use only one.
library;

export 'pdf.dart';
export 'plain_text.dart';
export 'slides.dart';
export 'spreadsheet.dart';
export 'src/common/document_controller.dart';
export 'src/common/document_format.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/common/text_decoding.dart';
export 'src/common/zip_safety_guard.dart';
export 'src/thumbnails/document_thumbnails.dart';
export 'src/viewer/document_viewer.dart';
export 'word.dart';
