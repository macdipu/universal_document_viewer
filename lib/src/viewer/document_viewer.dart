import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/document_format.dart';
import '../common/reader_contract.dart';
import '../common/zip_safety_guard.dart';
import '../engines/pdfium/pdf_types.dart';
import '../pdf_reader/pdf_document_controller.dart';
import '../pdf_reader/pdf_document_view.dart';
import '../sheets/sheet_grid.dart';
import '../sheets/spreadsheet_controller.dart';
import '../slides/slide_deck_controller.dart';
import '../slides/slide_deck_view.dart';
import '../text/text_document_controller.dart';
import '../text/text_document_view.dart';
import '../word/word_document_controller.dart';
import '../word/word_document_view.dart';

/// Opens any file universal_document_viewer reads and shows it with the matching
/// reader: PDF, Word, Excel (with sheet tabs), CSV, PowerPoint (with slide
/// navigation) or text.
///
/// A ready-made viewer for apps that just want to show a document; for
/// search UI, custom chrome or saving positions, use the per-format
/// controllers and views it's built from (see `pdf.dart`, `docx.dart`,
/// `sheets.dart`, `slides.dart`, `text.dart`).
class DocumentViewer extends StatefulWidget {
  const DocumentViewer.file(
    this.path, {
    super.key,
    this.initialPosition,
    this.onPositionChanged,
    this.errorBuilder,
    this.passwordProvider,
  });

  final String path;

  /// Where to reopen, as saved from [onPositionChanged].
  final ReadingPosition? initialPosition;

  /// Called as the reader moves; store the map to reopen there later.
  final ValueChanged<ReadingPosition>? onPositionChanged;

  /// Shown when the file can't be opened. Defaults to a short message.
  final Widget Function(BuildContext context, DocumentLoadError error)? errorBuilder;

  /// Asked for the password of an encrypted PDF, once per attempt, until it
  /// returns null (give up) or the password works. Without one an encrypted
  /// PDF shows [DocumentLoadError.passwordRequired].
  final PdfPasswordProvider? passwordProvider;

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  ChangeNotifier? _controller;
  DocumentLoadError? _error;
  bool _loading = true;

  /// Bumped per [_open], so a load that finishes after the path changed (or
  /// the viewer went away) disposes its controller instead of showing it.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(DocumentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path == oldWidget.path) return;
    _controller?.dispose();
    _controller = null;
    _error = null;
    _loading = true;
    _open();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    final at = widget.initialPosition;
    final report = widget.onPositionChanged;
    final file = File(widget.path);
    ChangeNotifier? controller;
    DocumentLoadError? error;
    try {
      switch (DocumentFormat.fromPath(widget.path)) {
        case null:
          error = DocumentLoadError.unsupported;
        case DocumentFormat.pdf:
          // The PDF engine reads the file itself (and asks for passwords).
          controller = PdfDocumentController(initialPosition: at, onPositionChanged: report);
        case DocumentFormat.word:
          final word = WordDocumentController(initialPosition: at, onPositionChanged: report);
          controller = word;
          if (await _readOffice(file) case final bytes?) {
            await word.load(bytes);
            error = word.error;
          } else {
            error = DocumentLoadError.tooLarge;
          }
        case DocumentFormat.excel:
          final sheet = SpreadsheetController(initialPosition: at, onPositionChanged: report);
          controller = sheet;
          if (await _readOffice(file) case final bytes?) {
            await sheet.loadXlsx(bytes);
            error = sheet.error;
          } else {
            error = DocumentLoadError.tooLarge;
          }
        case DocumentFormat.csv:
          final sheet = SpreadsheetController(initialPosition: at, onPositionChanged: report);
          controller = sheet;
          if (await file.length() > SpreadsheetController.maxCsvBytes) {
            sheet.rejectAsTooLarge();
          } else {
            await sheet.loadCsv(await file.readAsBytes());
          }
          error = sheet.error;
        case DocumentFormat.powerpoint:
          final deck = SlideDeckController(initialPosition: at, onPositionChanged: report);
          controller = deck;
          if (await _readOffice(file) case final bytes?) {
            await deck.load(bytes);
            error = deck.error;
          } else {
            error = DocumentLoadError.tooLarge;
          }
        case DocumentFormat.text:
          final text = TextDocumentController(initialPosition: at, onPositionChanged: report);
          controller = text;
          if (await file.length() > TextDocumentController.maxBytes) {
            error = DocumentLoadError.tooLarge;
          } else {
            text.load(await file.readAsBytes());
            error = text.error;
          }
      }
    } catch (_) {
      error = DocumentLoadError.corrupted;
    }
    if (!mounted || generation != _generation) {
      controller?.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _error = error;
      _loading = false;
    });
  }

  /// The Office file's bytes, or null when it is over
  /// [ZipSafetyGuard.maxFileBytes] - checked before reading, so a huge file
  /// is never pulled into memory only to be refused.
  static Future<Uint8List?> _readOffice(File file) async =>
      await file.length() > ZipSafetyGuard.maxFileBytes ? null : await file.readAsBytes();

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return widget.errorBuilder?.call(context, error) ?? Center(child: Text(_errorText(error), textAlign: TextAlign.center));
    }
    return switch (_controller) {
      final PdfDocumentController pdf => PdfDocumentView(
          path: widget.path,
          controller: pdf,
          passwordProvider: widget.passwordProvider,
          errorBuilder: (context, error) {
            final loadError = _pdfError(error);
            return widget.errorBuilder?.call(context, loadError) ?? Center(child: Text(_errorText(loadError)));
          },
        ),
      final WordDocumentController word => WordDocumentView(controller: word),
      final SpreadsheetController sheet => _SheetWithTabs(controller: sheet),
      final SlideDeckController deck => Column(
          children: [
            Expanded(child: SlideDeckView(controller: deck)),
            if (deck.slides.isNotEmpty) SlideNavigationBar(controller: deck),
          ],
        ),
      final TextDocumentController text => TextDocumentView(controller: text),
      _ => Center(child: Text(_errorText(DocumentLoadError.unsupported))),
    };
  }

  /// An encrypted PDF the reader couldn't unlock - no password, a wrong
  /// one, or an encryption PDFium doesn't support - is password protected,
  /// not damaged.
  static DocumentLoadError _pdfError(Object error) => switch (error) {
        PdfOpenException(error: PdfOpenError.password || PdfOpenError.security) => DocumentLoadError.passwordRequired,
        _ => DocumentLoadError.corrupted,
      };

  static String _errorText(DocumentLoadError error) => switch (error) {
        DocumentLoadError.tooLarge => 'This document is too large to open.',
        DocumentLoadError.corrupted => 'This document may be damaged or incomplete.',
        DocumentLoadError.passwordRequired => 'This document is password protected.',
        DocumentLoadError.unsupported => 'This file type is not supported.',
      };
}

/// [SheetGrid] with a tab per sheet when there's more than one.
class _SheetWithTabs extends StatelessWidget {
  const _SheetWithTabs({required this.controller});

  final SpreadsheetController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        children: [
          Expanded(child: SheetGrid(key: ValueKey(controller.activeSheetIndex), controller: controller)),
          if (controller.sheetNames.length > 1)
            SafeArea(
              top: false,
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
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
              ),
            ),
        ],
      ),
    );
  }
}
