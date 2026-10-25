import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

import '../library.dart';
import 'reader_page.dart';
import 'sheet_page.dart';
import 'word_page.dart';

/// The samples and your opened files as cards, each with a thumbnail of the
/// page it resumes on. Tap to open with DocumentViewer; Word and spreadsheet
/// files also open in their own reader from the card's menu.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.library});

  final DocumentLibrary library;

  Future<void> _pick(BuildContext context) async {
    final file = await openFile(
      acceptedTypeGroups: [XTypeGroup(label: 'Documents', extensions: DocumentFormat.supportedExtensions.toList())],
    );
    if (file == null || !context.mounted) return;
    library.addOpened(file.path);
    _open(context, file.path, _Reader.viewer);
  }

  void _open(BuildContext context, String path, _Reader reader) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => switch (reader) {
          _Reader.viewer => ReaderPage(library: library, path: path),
          _Reader.word => WordPage(library: library, path: path),
          _Reader.sheet => SheetPage(library: library, path: path),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _pick(context),
        icon: const Icon(Icons.folder_open),
        label: const Text('Open file'),
      ),
      body: ListenableBuilder(
        listenable: library,
        builder: (context, _) => CustomScrollView(
          slivers: [
            SliverAppBar.medium(
              title: const Text('Document Viewer'),
              actions: [
                IconButton(
                  tooltip: 'Forget reading positions',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: library.forgetPositions,
                ),
              ],
            ),
            const SliverToBoxAdapter(child: _Intro()),
            if (library.opened.isNotEmpty) ...[const _Header('Your files'), _grid(context, library.opened)],
            const _Header('Samples'),
            _grid(context, library.samples),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<String> paths) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemCount: paths.length,
        itemBuilder: (context, index) => _card(context, paths[index]),
      ),
    );
  }

  Widget _card(BuildContext context, String path) {
    final format = DocumentFormat.fromPath(path);
    final position = library.positionOf(path);
    final dedicated = switch (format) {
      DocumentFormat.word => _Reader.word,
      DocumentFormat.excel || DocumentFormat.csv => _Reader.sheet,
      _ => null,
    };
    final locked = fileName(path) == 'locked.pdf';
    final theme = Theme.of(context);
    return Card.outlined(
      key: ValueKey(path),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _open(context, path, _Reader.viewer),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Thumbnail(path: path, position: position, locked: locked),
                  Positioned(left: 8, top: 8, child: _FormatBadge(format)),
                  if (dedicated != null)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: PopupMenuButton<_Reader>(
                        tooltip: 'Open with',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (reader) => _open(context, path, reader),
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: _Reader.viewer, child: Text('Open with DocumentViewer')),
                          PopupMenuItem(
                            value: dedicated,
                            child: Text(
                              dedicated == _Reader.word ? 'Open in the Word reader' : 'Open in the sheet reader',
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fileName(path), style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    locked
                        ? 'Password: ${DocumentLibrary.lockedPdfPassword}'
                        : resumeHint(position) ?? 'Not opened yet',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Where a saved position resumes, in words; null at the start.
  static String? resumeHint(ReadingPosition? position) {
    if (position == null) return null;
    if (position[PositionKeys.pageNumber] case final int page when page > 1) return 'Resumes on page $page';
    if (position[PositionKeys.slideIndex] case final int slide when slide > 0) return 'Resumes on slide ${slide + 1}';
    if (position[PositionKeys.line] case final int line when line > 0) return 'Resumes on line ${line + 1}';
    if (position[PositionKeys.paragraph] case final int paragraph when paragraph > 0) {
      return 'Resumes on paragraph ${paragraph + 1}';
    }
    final sheet = position[PositionKeys.sheetIndex];
    final row = position[PositionKeys.row];
    if ((sheet is int && sheet > 0) || (row is int && row > 0)) {
      final where = [if (sheet is int && sheet > 0) 'sheet ${sheet + 1}', if (row is int && row > 0) 'row ${row + 1}'];
      return 'Resumes on ${where.join(', ')}';
    }
    return null;
  }
}

enum _Reader { viewer, word, sheet }

/// The label and colour each format is shown with.
extension on DocumentFormat? {
  (String, Color) get look => switch (this) {
    DocumentFormat.pdf => ('PDF', const Color(0xFFC62828)),
    DocumentFormat.word => ('Word', const Color(0xFF1565C0)),
    DocumentFormat.excel => ('Excel', const Color(0xFF2E7D32)),
    DocumentFormat.csv => ('CSV', const Color(0xFF00796B)),
    DocumentFormat.powerpoint => ('Slides', const Color(0xFFE65100)),
    DocumentFormat.text => ('Text', const Color(0xFF546E7A)),
    null => ('Other', const Color(0xFF757575)),
  };
}

/// What the package reads, as a row of format badges.
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Every document opens with one widget. Tap a sample to read it; '
            'come back and its card shows where you stopped.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final format in DocumentFormat.values) _FormatBadge(format)]),
        ],
      ),
    );
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge(this.format);

  final DocumentFormat? format;

  @override
  Widget build(BuildContext context) {
    final (label, color) = format.look;
    return DecoratedBox(
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

/// [DocumentThumbnails] of the page [position] is on. Renders are kept per
/// page, so moving within a page doesn't redraw.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path, this.position, this.locked = false});

  final String path;
  final ReadingPosition? position;
  final bool locked;

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
    final page = {for (final key in _pageKeys) key: ?position?[key]};
    final render = _renders.putIfAbsent(
      '$path|$page',
      () => DocumentThumbnails.render(path, width: 360, position: page.isEmpty ? null : page),
    );
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: FutureBuilder<Uint8List?>(
        future: render,
        builder: (context, snapshot) => switch (snapshot.data) {
          final png? => Image.memory(png, fit: BoxFit.cover, alignment: Alignment.topCenter),
          null when snapshot.connectionState == ConnectionState.done => Icon(
            locked ? Icons.lock_outline : Icons.description_outlined,
            size: 40,
            color: scheme.onSurfaceVariant,
          ),
          null => const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        },
      ),
    );
  }
}
