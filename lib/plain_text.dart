/// Plain text documents (.txt, logs and the like).
///
/// [PlainTextView] shows the lines a [PlainTextController] has loaded, with
/// search highlights, wrapped or not. For Markdown, see `markdown.dart`.
library;

export 'src/common/document_controller.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/common/text_lines_controller.dart' show TextLinesController, TextMatch;
export 'src/plain_text/plain_text_controller.dart';
export 'src/plain_text/plain_text_view.dart';
