/// PowerPoint (.pptx) presentations.
///
/// [SlidesView] shows the slides a [SlidesController] has loaded, one at a
/// time, as a reading view: each slide's title, text, tables and pictures.
///
/// [PptxParser] reads a file into a [PptxPresentation] without showing it.
library;

export 'src/common/document_controller.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/slides/pptx_parser.dart';
export 'src/slides/slides_controller.dart';
export 'src/slides/slides_view.dart';
