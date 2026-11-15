/// Plain text documents (.txt, logs and the like) and Markdown (.md).
///
/// [PlainTextView] shows the lines a [PlainTextController] has loaded, with
/// search highlights, wrapped or not. [MarkdownView] shows a
/// [MarkdownController]'s document as a rendered preview, highlighted source
/// or both side by side.
library;

export 'src/common/document_controller.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/common/text_lines_controller.dart' show TextLinesController, TextMatch;
export 'src/plain_text/plain_text_controller.dart';
export 'src/plain_text/plain_text_view.dart';
