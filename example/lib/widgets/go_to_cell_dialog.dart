import 'package:flutter/material.dart';
import 'package:universal_document_viewer/spreadsheet.dart';

/// Asks for a cell or sheet and goes there with
/// [SpreadsheetController.goToCell]: `D120`, `Sheet2!B3`, or a sheet's name
/// (the sheets are offered as chips). Stays open with a message when
/// there's no such place.
Future<void> showGoToCellDialog(BuildContext context, SpreadsheetController controller) {
  return showDialog<void>(
    context: context,
    builder: (_) => _GoToDialog(controller: controller),
  );
}

class _GoToDialog extends StatefulWidget {
  const _GoToDialog({required this.controller});

  final SpreadsheetController controller;

  @override
  State<_GoToDialog> createState() => _GoToDialogState();
}

class _GoToDialogState extends State<_GoToDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _go(String reference) {
    if (widget.controller.goToCell(reference)) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = 'No cell or sheet called "${reference.trim()}"');
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.controller.sheetNames;
    return AlertDialog(
      title: const Text('Go to'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _field,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              labelText: 'Cell',
              hintText: names.length > 1 ? 'D120 or ${names[1]}!B3' : 'D120',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: _go,
          ),
          if (names.length > 1) ...[
            const SizedBox(height: 16),
            Text('Sheets', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < names.length; i++)
                  ChoiceChip(
                    label: Text(names[i]),
                    selected: i == widget.controller.activeSheetIndex,
                    onSelected: (_) {
                      widget.controller.switchSheet(i);
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => _go(_field.text), child: const Text('Go')),
      ],
    );
  }
}
