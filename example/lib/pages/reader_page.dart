import 'package:flutter/material.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

import '../library.dart';

/// Any document in the ready-made [DocumentViewer], reopening where it was
/// left and saving where it is now. A password-protected PDF asks for its
/// password.
class ReaderPage extends StatelessWidget {
  const ReaderPage({super.key, required this.library, required this.path});

  final DocumentLibrary library;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(fileName(path))),
      body: DocumentViewer.file(
        path,
        initialPosition: library.positionOf(path),
        onPositionChanged: (position) => library.savePosition(path, position),
        passwordProvider: () => _askPassword(context),
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              switch (error) {
                DocumentLoadError.tooLarge => 'This file is too large to open.',
                DocumentLoadError.corrupted => 'This file is damaged or not what its name says.',
                DocumentLoadError.passwordRequired => 'This PDF needs a password.',
                DocumentLoadError.unsupported => 'universal_document_viewer doesn\'t read this kind of file.',
              },
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  /// The PDF's password, or null to give up; asked again after a wrong one.
  static Future<String?> _askPassword(BuildContext context) =>
      showDialog<String>(context: context, builder: (_) => const _PasswordDialog());
}

/// Owns its text field's controller: disposing it when the dialog's future
/// completes would be too early, as the dialog still animates out.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Password'),
      content: TextField(
        controller: _field,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'This PDF is protected'),
        onSubmitted: (text) => Navigator.of(context).pop(text),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_field.text), child: const Text('Open')),
      ],
    );
  }
}
