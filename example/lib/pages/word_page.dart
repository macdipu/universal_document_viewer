import 'dart:io';

import 'package:flutter/material.dart';
import 'package:universal_document_viewer/docx.dart';

import '../library.dart';

/// A `.docx` in its own reader - [WordDocumentController] and
/// [WordDocumentView] - with search and the continuous / print layout
/// switch in the app bar.
class WordPage extends StatefulWidget {
  const WordPage({super.key, required this.library, required this.path});

  final DocumentLibrary library;
  final String path;

  @override
  State<WordPage> createState() => _WordPageState();
}

class _WordPageState extends State<WordPage> {
  late final _controller = WordDocumentController(
    initialPosition: widget.library.positionOf(widget.path),
    onPositionChanged: (position) => widget.library.savePosition(widget.path, position),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _controller.load(await File(widget.path).readAsBytes());
    } on FileSystemException {
      if (mounted) _controller.rejectAsCorrupted();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = _controller.searchController;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(hintText: 'Search', border: InputBorder.none),
          onChanged: _controller.search,
        ),
        actions: [
          ListenableBuilder(
            listenable: search,
            builder: (context, _) => Center(
              child: Text(search.matchCount == 0 ? '' : '${search.currentMatchIndex + 1}/${search.matchCount}'),
            ),
          ),
          IconButton(icon: const Icon(Icons.keyboard_arrow_up), onPressed: _controller.previousMatch),
          IconButton(icon: const Icon(Icons.keyboard_arrow_down), onPressed: _controller.nextMatch),
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => IconButton(
              icon: Icon(_controller.viewMode == WordViewMode.paged ? Icons.view_agenda_outlined : Icons.article_outlined),
              tooltip: _controller.viewMode == WordViewMode.paged ? 'Continuous layout' : 'Print layout',
              onPressed: _controller.toggleViewMode,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        // The view shows a spinner until the document is parsed.
        builder: (context, _) => switch (_controller.error) {
          null => WordDocumentView(controller: _controller),
          final error => Center(child: Text('Could not open the document (${error.name}).')),
        },
      ),
    );
  }
}
