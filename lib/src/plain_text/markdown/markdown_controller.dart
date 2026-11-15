
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../common/document_controller.dart';
import '../../common/reader_contract.dart';
import '../plain_text_controller.dart';
import 'markdown_stats.dart';

/// A Markdown document for [MarkdownView]: a [PlainTextController] (so it
/// loads, decodes and searches the source the same way) plus how it is shown.
///
/// [viewMode] picks Preview, Code or Split. Searching from Preview switches to
/// Code, because matches are highlighted in the source. The reading position
/// is one 0..1 ratio shared by every mode, so switching modes, split scrolling
/// and a saved position all agree.
class MarkdownController extends PlainTextController {
  /// Opens a document in [mode] (Preview unless told otherwise).
  MarkdownController(
      {super.initialPosition,
      super.onPositionChanged,
      this.baseDirectory,
      MarkdownViewMode mode = MarkdownViewMode.preview})
      : viewMode = ValueNotifier(mode);

  /// Whether [extension] (with or without the dot) names a Markdown file.
  static bool isMarkdownExtension(String extension) =>
      const {'md', 'markdown'}.contains(extension.toLowerCase().replaceFirst('.', ''));

  /// How the document is shown.
  final ValueNotifier<MarkdownViewMode> viewMode;

  /// Where relative image paths resolve from. [loadFile] sets it to the
  /// file's folder unless the app already did.
  String? baseDirectory;

  /// Source-equivalent offset per line in the saved position, so a saved
  /// offset doesn't depend on the font size or the mode it was read in.
  static const double unitsPerLine = 20;

  /// Shows the document in [mode].
  void setViewMode(MarkdownViewMode mode) => viewMode.value = mode;

  @override
  Future<void> loadFile(String path) {
    baseDirectory ??= p.dirname(path);
    return super.loadFile(path);
  }

  @override
  Future<void> loadBytes(Uint8List bytes) async {
    _stats = null;
    await super.loadBytes(bytes);
  }

  MarkdownStats? _stats;

  /// Counts for the loaded source, computed once per load.
  MarkdownStats get stats => _stats ??= MarkdownStats.of(lines);

  /// The whole source, for copying.
  String get source => lines.join('\n');

  /// Finds [query] in the source; from Preview this shows the source first.
  @override
  void search(String query) {
    if (query.isNotEmpty && viewMode.value == MarkdownViewMode.preview) viewMode.value = MarkdownViewMode.code;
    super.search(query);
  }

  // ---- Where the reader is

  double _ratio = -1;

  /// The saved position as a 0..1 ratio of the document.
  double get initialRatio {
    final total = lines.length * unitsPerLine;
    return total <= 0 ? 0 : (initialScrollOffset / total).clamp(0.0, 1.0);
  }

  /// Set by the view: scrolls the source so line [line] (from 0) is at the top.
  @internal
  void Function(int line)? lineJumper;

  /// [MarkdownView] reports every scroll here, as a ratio in 0..1.
  @internal
  void onMarkdownScrolled(double ratio) {
    _ratio = ratio.clamp(0.0, 1.0);
    updateLocation(DocumentLocation(current: _topLine + 1, count: lines.length, unit: DocumentUnit.line));
    reportPosition();
  }

  int get _topLine => lines.isEmpty ? 0 : (_ratio.clamp(0.0, 1.0) * (lines.length - 1)).floor();

  @override
  ReadingPosition get position => {
        PositionKeys.scrollOffset: (_ratio < 0 ? initialRatio : _ratio) * lines.length * unitsPerLine,
        if (_ratio >= 0) PositionKeys.line: _topLine,
      };

  /// Scrolls line [number] (from 1) to the top of the source, showing it first
  /// when only the preview is up.
  @override
  void goTo(int number) {
    final jump = lineJumper;
    if (lines.isEmpty || jump == null) return deferGoTo(number);
    if (viewMode.value == MarkdownViewMode.preview) viewMode.value = MarkdownViewMode.code;
    jump(number.clamp(1, lines.length) - 1);
  }

  @override
  void dispose() {
    viewMode.dispose();
    super.dispose();
  }
}
