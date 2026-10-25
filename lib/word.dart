/// Word (.docx) documents.
///
/// [WordView] shows a document that a [WordController] has loaded, either
/// reflowed to the screen or as printed pages ([WordViewMode]).
/// [WordPageThumbnail] draws one page small, for a page strip.
///
/// To read a document's content without showing it, parse it with
/// [DocxReader] into a [WordDocument].
library;

export 'src/common/document_controller.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/engines/word/docx_reader.dart';
export 'src/engines/word/word_model.dart';
export 'src/word/word_controller.dart';
export 'src/word/word_view.dart' show WordPageThumbnail, WordView;
