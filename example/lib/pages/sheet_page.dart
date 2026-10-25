import 'package:flutter/material.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

import '../library.dart';
import '../widgets/go_to_cell_dialog.dart';

/// An Excel workbook or CSV in [SpreadsheetView], with what a reader app adds
/// around it: sheet tabs, search, go to a cell and freezing the header row.
class SheetPage extends StatefulWidget {
  const SheetPage({super.key, required this.library, required this.path});

  final DocumentLibrary library;
  final String path;

  @override
  State<SheetPage> createState() => _SheetPageState();
}

class _SheetPageState extends State<SheetPage> {
  late final _controller = SpreadsheetController(
    initialPosition: widget.library.positionOf(widget.path),
    onPositionChanged: (position) => widget.library.savePosition(widget.path, position),
  );
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    // An .xlsx workbook or a .csv file, by its extension; an oversized file
    // is refused before it is read.
    _controller.loadFile(widget.path);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final loaded = _controller.isLoaded && _controller.error == null;
        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Search this sheet',
                      border: InputBorder.none,
                      suffixText: DocumentViewerStrings.of(context).searchStatus(_controller.searchState.value),
                    ),
                    onChanged: _controller.search,
                    onSubmitted: (_) => _controller.nextMatch(),
                  )
                : Text(fileName(widget.path)),
            actions: [
              IconButton(
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _controller.clearSearch();
                }),
              ),
              if (loaded)
                PopupMenuButton<String>(
                  onSelected: (action) => switch (action) {
                    'goto' => showGoToCellDialog(context, _controller),
                    _ => _controller.freezeTopRow = !_controller.freezeTopRow,
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'goto', child: Text('Go to cell')),
                    if (!_controller.sheetFreezesRows)
                      CheckedPopupMenuItem(
                        value: 'freeze',
                        checked: _controller.freezeTopRow,
                        child: const Text('Freeze header row'),
                      ),
                  ],
                ),
            ],
          ),
          body: switch ((_controller.isLoaded, _controller.error)) {
            (false, _) => const Center(child: CircularProgressIndicator()),
            (_, final error?) => Center(child: Text('Could not open the file (${error.name}).')),
            // Each sheet gets its own grid, so its scroll offsets start fresh.
            _ => SpreadsheetView(key: ValueKey(_controller.activeSheetIndex), controller: _controller),
          },
          bottomNavigationBar: loaded && _controller.sheetNames.length > 1
              ? NavigationBar(
                  selectedIndex: _controller.activeSheetIndex,
                  onDestinationSelected: _controller.switchSheet,
                  destinations: [
                    for (final name in _controller.sheetNames)
                      NavigationDestination(icon: const Icon(Icons.grid_on), label: name),
                  ],
                )
              : null,
        );
      },
    );
  }
}
