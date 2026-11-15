/// Markdown documents (.md).
///
/// [MarkdownView] shows a [MarkdownController]'s document as a rendered
/// preview, as highlighted source with line numbers, or both side by side.
library;

export 'src/common/document_controller.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/common/text_lines_controller.dart' show TextLinesController, TextMatch;
export 'src/markdown/markdown_controller.dart';
export 'src/markdown/markdown_stats.dart';
export 'src/markdown/markdown_view.dart';
