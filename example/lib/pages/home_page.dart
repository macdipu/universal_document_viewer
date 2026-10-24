import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

import '../library.dart';
import 'reader_page.dart';
import 'sheet_page.dart';
import 'word_page.dart';

/// The samples and your opened files, each with a thumbnail of the page it
/// resumes on. Tap to open with DocumentViewer; Word and spreadsheet files
/// also open in their own reader from the row's menu.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.library});

  final DocumentLibrary library;

  Future<void> _pick(BuildContext context) async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: 'Documents', extensions: DocumentFormat.supportedExtensions.toList()),
      ],
    );
    if (file == null || !context.mounted) return;
    library.addOpened(file.path);
    _open(context, file.path, _Reader.viewer);
  }

  void _open(BuildContext context, String path, _Reader reader) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => switch (reader) {
        _Reader.viewer => ReaderPage(library: library, path: path),
        _Reader.word => WordPage(library: library, path: path),
        _Reader.sheet => SheetPage(library: library, path: path),
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('universal_document_viewer'),
        actions: [
          IconButton(
            tooltip: 'Forget reading positions',
            icon: const Icon(Icons.restart_alt),
            onPressed: library.forgetPositions,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _pick(context),
        icon: const Icon(Icons.folder_open),
        label: const Text('Open file'),
      ),
      body: ListenableBuilder(
        listenable: library,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (library.opened.isNotEmpty) ...[
              const _Header('Your files'),
              for (final path in library.opened) _row(context, path),
            ],
            const _Header('Samples'),
            for (final path in library.samples) _row(context, path),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('locked.pdf asks for a password: "${DocumentLibrary.lockedPdfPassword}".'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String path) {
    final format = DocumentFormat.fromPath(path);
    final position = library.positionOf(path);
    final dedicated = switch (format) {
      DocumentFormat.word => _Reader.word,
      DocumentFormat.excel || DocumentFormat.csv => _Reader.sheet,
      _ => null,
    };
    return ListTile(
      key: ValueKey(path),
      leading: _Thumbnail(path: path, position: position),
      title: Text(fileName(path)),
      subtitle: Text([format?.name ?? 'unsupported', ?resumeHint(position)].join(' · ')),
      onTap: () => _open(context, path, _Reader.viewer),
      trailing: dedicated == null
          ? null
          : PopupMenuButton<_Reader>(
              onSelected: (reader) => _open(context, path, reader),
              itemBuilder: (_) => [
                const PopupMenuItem(value: _Reader.viewer, child: Text('Open with DocumentViewer')),
                PopupMenuItem(
                  value: dedicated,
                  child: Text(dedicated == _Reader.word ? 'Open in the Word reader' : 'Open in the sheet reader'),
                ),
              ],
            ),
    );
  }

  /// Where a saved position resumes, in words; null at the start.
  static String? resumeHint(ReadingPosition? position) {
    if (position == null) return null;
    if (position[PositionKeys.pageNumber] case final int page when page > 1) return 'page $page';
    if (position[PositionKeys.slideIndex] case final int slide when slide > 0) return 'slide ${slide + 1}';
    if (position[PositionKeys.line] case final int line when line > 0) return 'line ${line + 1}';
    if (position[PositionKeys.paragraph] case final int paragraph when paragraph > 0) return 'paragraph ${paragraph + 1}';
    final sheet = position[PositionKeys.sheetIndex];
    final row = position[PositionKeys.row];
    if ((sheet is int && sheet > 0) || (row is int && row > 0)) {
      return [if (sheet is int && sheet > 0) 'sheet ${sheet + 1}', if (row is int && row > 0) 'row ${row + 1}'].join(', ');
    }
    return null;
  }
}

enum _Reader { viewer, word, sheet }

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// [DocumentThumbnails] of the page [position] is on. Renders are kept per
/// page, so moving within a page doesn't redraw.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path, this.position});

  final String path;
  final ReadingPosition? position;

  static final _renders = <String, Future<Uint8List?>>{};

  static const _pageKeys = [
    PositionKeys.pageNumber,
    PositionKeys.paragraph,
    PositionKeys.slideIndex,
    PositionKeys.sheetIndex,
    PositionKeys.row,
    PositionKeys.column,
    PositionKeys.line,
  ];

  @override
  Widget build(BuildContext context) {
    final page = {for (final key in _pageKeys) if (position?[key] case final value?) key: value};
    final render = _renders.putIfAbsent(
      '$path|$page',
      () => DocumentThumbnails.render(path, width: 120, position: page.isEmpty ? null : page),
    );
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      height: 56,
      child: FutureBuilder<Uint8List?>(
        future: render,
        builder: (context, snapshot) => DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), color: scheme.surfaceContainer),
          child: switch (snapshot.data) {
            final png? => Image.memory(png, fit: BoxFit.cover, alignment: Alignment.topCenter),
            null when snapshot.connectionState == ConnectionState.done =>
              Icon(Icons.description_outlined, color: scheme.onSurfaceVariant),
            null => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }
}
