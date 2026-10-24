import 'dart:io';

import 'package:flutter/material.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/sheets.dart';

import '../library.dart';

/// An Excel workbook or CSV in [SheetGrid], with what a reader app adds
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
    _load();
  }

  Future<void> _load() async {
    final file = File(widget.path);
    final csv = DocumentFormat.fromPath(widget.path) == DocumentFormat.csv;
    try {
      // Refuse an oversized CSV before reading it into memory.
      if (csv && await file.length() > SpreadsheetController.maxCsvBytes) {
        _controller.rejectAsTooLarge();
        return;
      }
      final bytes = await file.readAsBytes();
      await (csv ? _controller.loadCsv(bytes) : _controller.loadXlsx(bytes));
    } on FileSystemException {
      if (mounted) _controller.rejectAsTooLarge();
    }
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
                      suffixText: _controller.matches.isEmpty
                          ? null
                          : '${_controller.currentMatchIndex + 1}/${_controller.matches.length}',
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
                    'goto' => showGoToDialog(context, _controller),
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
            _ => SheetGrid(key: ValueKey(_controller.activeSheetIndex), controller: _controller),
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
