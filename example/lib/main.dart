import 'package:flutter/material.dart';

import 'library.dart';
import 'pages/home_page.dart';

/// A test app for universal_document_viewer: sample documents in every format the kit
/// reads, opened with the ready-made DocumentViewer or with the per-format
/// readers, plus your own files. Reading positions are saved, so reopening
/// a document (and its thumbnail) resumes where you left off.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = await DocumentLibrary.load();
  runApp(ExampleApp(library: library));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.library});

  final DocumentLibrary library;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'universal_document_viewer',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
      home: HomePage(library: library),
    );
  }
}
