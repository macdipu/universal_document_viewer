import 'package:flutter/material.dart';
import 'package:universal_document_viewer/word.dart';

import '../library.dart';

/// A `.docx` in its own reader - [WordController] and
/// [WordView] - with search and the continuous / print layout
/// switch in the app bar.
class WordPage extends StatefulWidget {
  const WordPage({super.key, required this.library, required this.path});

  final DocumentLibrary library;
  final String path;

  @override
  State<WordPage> createState() => _WordPageState();
}

class _WordPageState extends State<WordPage> {
  late final _controller = WordController(
    initialPosition: widget.library.positionOf(widget.path),
    onPositionChanged: (position) => widget.library.savePosition(widget.path, position),
  );

  @override
  void initState() {
    super.initState();
    _controller.loadFile(widget.path);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(hintText: 'Search', border: InputBorder.none),
          onChanged: _controller.search,
        ),
        actions: [
          ValueListenableBuilder(
            valueListenable: _controller.searchState,
            builder: (context, search, _) =>
                Center(child: Text(DocumentViewerStrings.of(context).searchStatus(search))),
          ),
          IconButton(icon: const Icon(Icons.keyboard_arrow_up), onPressed: _controller.previousMatch),
          IconButton(icon: const Icon(Icons.keyboard_arrow_down), onPressed: _controller.nextMatch),
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => IconButton(
              icon: Icon(
                _controller.viewMode == WordViewMode.paged ? Icons.view_agenda_outlined : Icons.article_outlined,
              ),
              tooltip: _controller.viewMode == WordViewMode.paged ? 'Continuous layout' : 'Print layout',
              onPressed: _controller.toggleViewMode,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => switch (_controller.status) {
          DocumentStatus.idle || DocumentStatus.loading => const Center(child: CircularProgressIndicator()),
          DocumentStatus.failed => Center(
            child: Text(DocumentViewerStrings.of(context).loadError(_controller.error!), textAlign: TextAlign.center),
          ),
          DocumentStatus.ready => WordView(controller: _controller),
        },
      ),
    );
  }
}
