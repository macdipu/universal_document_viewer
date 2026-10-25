import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/document_controller.dart';
import '../common/document_format.dart';
import '../common/document_viewer_strings.dart';
import '../common/reader_contract.dart';
import '../pdf/pdf_controller.dart';
import '../pdf/pdf_view.dart';
import '../plain_text/plain_text_controller.dart';
import '../plain_text/plain_text_view.dart';
import '../slides/slides_controller.dart';
import '../slides/slides_view.dart';
import '../spreadsheet/spreadsheet_controller.dart';
import '../spreadsheet/spreadsheet_view.dart';
import '../word/word_controller.dart';
import '../word/word_view.dart';

/// Shows any document the package reads, with the matching reader and a
/// small toolbar: PDF, Word, Excel (with sheet tabs), CSV, PowerPoint or
/// plain text.
///
/// ```dart
/// DocumentViewer.file(path)
/// ```
///
/// The toolbar shows where the reader is, steps between pages or slides,
/// zooms and searches; hide it with `showToolbar: false`. For your own
/// toolbar or layout, use the format's controller and view instead (see
/// [DocumentController]).
class DocumentViewer extends StatefulWidget {
  /// Shows the document at [path], choosing the reader by its extension.
  const DocumentViewer.file(
    String this.path, {
    super.key,
    this.initialPosition,
    this.onPositionChanged,
    this.errorBuilder,
    this.passwordProvider,
    this.showToolbar = true,
  }) : bytes = null,
       format = null;

  /// Shows a document held in memory, of the given [format].
  const DocumentViewer.bytes(
    Uint8List this.bytes, {
    required DocumentFormat this.format,
    super.key,
    this.initialPosition,
    this.onPositionChanged,
    this.errorBuilder,
    this.passwordProvider,
    this.showToolbar = true,
  }) : path = null;

  /// The file to show, for [DocumentViewer.file].
  final String? path;

  /// The document's bytes, for [DocumentViewer.bytes].
  final Uint8List? bytes;

  /// What [bytes] are, for [DocumentViewer.bytes].
  final DocumentFormat? format;

  /// Where to reopen, as saved from [onPositionChanged].
  final ReadingPosition? initialPosition;

  /// Called as the reader moves; save the map to reopen there later.
  final ValueChanged<ReadingPosition>? onPositionChanged;

  /// Shown when the document can't be opened. Defaults to a short message
  /// from [DocumentViewerStrings.loadError].
  final Widget Function(BuildContext context, DocumentLoadError error)? errorBuilder;

  /// Asked for the password of an encrypted PDF, once per attempt, until it
  /// returns null (give up) or the password works. Without one an encrypted
  /// PDF shows [DocumentLoadError.passwordRequired].
  final PdfPasswordProvider? passwordProvider;

  /// Whether to show the toolbar under the document.
  final bool showToolbar;

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  DocumentController? _controller;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(DocumentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path == oldWidget.path &&
        identical(widget.bytes, oldWidget.bytes) &&
        widget.format == oldWidget.format) {
      return;
    }
    _controller?.dispose();
    _open();
  }

  void _open() {
    final format = widget.format ?? DocumentFormat.fromPath(widget.path!);
    final at = widget.initialPosition;
    final report = widget.onPositionChanged;
    final controller = switch (format) {
      null => null,
      DocumentFormat.pdf => PdfController(
        initialPosition: at,
        onPositionChanged: report,
        passwordProvider: widget.passwordProvider,
      ),
      DocumentFormat.word => WordController(initialPosition: at, onPositionChanged: report),
      DocumentFormat.excel ||
      DocumentFormat.csv => SpreadsheetController(initialPosition: at, onPositionChanged: report, format: format),
      DocumentFormat.powerpoint => SlidesController(initialPosition: at, onPositionChanged: report),
      DocumentFormat.text => PlainTextController(initialPosition: at, onPositionChanged: report),
    };
    _controller = controller;
    if (controller == null) return;
    if (widget.bytes case final bytes?) {
      controller.loadBytes(bytes);
    } else {
      controller.loadFile(widget.path!);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Widget _error(BuildContext context, DocumentLoadError error) =>
      widget.errorBuilder?.call(context, error) ??
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(DocumentViewerStrings.of(context).loadError(error), textAlign: TextAlign.center),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return _error(context, DocumentLoadError.unsupported);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        switch (controller.status) {
          case DocumentStatus.idle || DocumentStatus.loading:
            return const Center(child: CircularProgressIndicator());
          case DocumentStatus.failed:
            return _error(context, controller.error ?? DocumentLoadError.corrupted);
          case DocumentStatus.ready:
            break;
        }
        return Column(
          children: [
            Expanded(child: _view(controller)),
            if (controller case final SpreadsheetController sheet when sheet.sheetNames.length > 1)
              _SheetTabs(controller: sheet),
            if (widget.showToolbar) _Toolbar(controller: controller),
          ],
        );
      },
    );
  }

  Widget _view(DocumentController controller) => switch (controller) {
    final PdfController pdf => PdfView(controller: pdf, errorBuilder: _error),
    final WordController word => WordView(controller: word),
    final SpreadsheetController sheet => SpreadsheetView(key: ValueKey(sheet.activeSheetIndex), controller: sheet),
    final SlidesController slides => SlidesView(controller: slides),
    final PlainTextController text => PlainTextView(controller: text),
    _ => const SizedBox.shrink(),
  };
}

/// A tab per sheet, for a workbook with more than one.
class _SheetTabs extends StatelessWidget {
  const _SheetTabs({required this.controller});

  final SpreadsheetController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (var i = 0; i < controller.sheetNames.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: ChoiceChip(
                label: Text(controller.sheetNames[i]),
                selected: i == controller.activeSheetIndex,
                onSelected: (_) => controller.switchSheet(i),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where the reader is, page or slide steps, zoom and search: built only on
/// [DocumentController], so it's the same for every format.
class _Toolbar extends StatefulWidget {
  const _Toolbar({required this.controller});

  final DocumentController controller;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  bool _searching = false;
  final _query = TextEditingController();

  DocumentController get controller => widget.controller;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _query.clear();
    controller.clearSearch();
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final strings = DocumentViewerStrings.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(height: 52, child: _searching ? _searchRow(strings) : _mainRow(strings)),
      ),
    );
  }

  Widget _mainRow(DocumentViewerStrings strings) {
    return ValueListenableBuilder(
      valueListenable: controller.location,
      builder: (context, location, _) {
        final stepped = location.unit == DocumentUnit.page || location.unit == DocumentUnit.slide;
        return Row(
          children: [
            IconButton(
              tooltip: strings.search,
              icon: const Icon(Icons.search_rounded),
              onPressed: () => setState(() => _searching = true),
            ),
            const Spacer(),
            if (stepped)
              IconButton(
                tooltip: strings.previous,
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: location.current > 1 ? () => controller.goTo(location.current - 1) : null,
              ),
            Text(strings.location(location), style: Theme.of(context).textTheme.labelLarge),
            if (stepped)
              IconButton(
                tooltip: strings.next,
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: location.current < location.count ? () => controller.goTo(location.current + 1) : null,
              ),
            const Spacer(),
            IconButton(
              tooltip: strings.zoomOut,
              icon: const Icon(Icons.zoom_out_rounded),
              onPressed: controller.canZoomOut ? controller.zoomOut : null,
            ),
            IconButton(
              tooltip: strings.zoomIn,
              icon: const Icon(Icons.zoom_in_rounded),
              onPressed: controller.canZoomIn ? controller.zoomIn : null,
            ),
          ],
        );
      },
    );
  }

  Widget _searchRow(DocumentViewerStrings strings) {
    return Row(
      children: [
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(hintText: strings.search, border: InputBorder.none),
            onChanged: controller.search,
            // Enter steps to the next match; the field keeps focus.
            onSubmitted: (_) => controller.nextMatch(),
            onEditingComplete: () {},
          ),
        ),
        ValueListenableBuilder(
          valueListenable: controller.searchState,
          builder: (context, state, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(strings.searchStatus(state), style: Theme.of(context).textTheme.bodySmall),
              IconButton(
                tooltip: strings.previousMatch,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                onPressed: state.matchCount > 0 ? controller.previousMatch : null,
              ),
              IconButton(
                tooltip: strings.nextMatch,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onPressed: state.matchCount > 0 ? controller.nextMatch : null,
              ),
            ],
          ),
        ),
        IconButton(tooltip: strings.closeSearch, icon: const Icon(Icons.close_rounded), onPressed: _closeSearch),
      ],
    );
  }
}
