import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:path_provider/path_provider.dart';

/// The documents the example offers: the bundled samples (copied out of the
/// app's assets on first run, since the readers open files by path) and any
/// files picked with "Open file", each with its saved reading position.
///
/// Positions are kept in a JSON file next to the samples, the way an app
/// would store them: the maps the readers report are JSON-safe as they are.
class DocumentLibrary extends ChangeNotifier {
  DocumentLibrary._(this._directory, this.samples);

  /// Bundled with the app (see assets/samples and tool/make_samples.py).
  static const sampleNames = [
    'guide.pdf',
    'locked.pdf',
    'report.docx',
    'sales.xlsx',
    'contacts.csv',
    'deck.pptx',
    'notes.txt',
  ];

  /// The password of locked.pdf, for trying the PDF password prompt.
  static const lockedPdfPassword = 'open';

  static Future<DocumentLibrary> load() async {
    final directory = Directory('${(await getApplicationSupportDirectory()).path}/samples');
    await directory.create(recursive: true);
    final samples = <String>[];
    for (final name in sampleNames) {
      final file = File('${directory.path}/$name');
      if (!await file.exists()) {
        final data = await rootBundle.load('assets/samples/$name');
        await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      samples.add(file.path);
    }
    final library = DocumentLibrary._(directory, samples);
    await library._readPositions();
    return library;
  }

  final Directory _directory;
  final List<String> samples;

  /// Files picked with "Open file", newest first.
  final List<String> opened = [];

  final Map<String, ReadingPosition> _positions = {};

  File get _positionsFile => File('${_directory.path}/positions.json');

  ReadingPosition? positionOf(String path) => _positions[path];

  /// Called by the readers as they move; saved straight away (an app would
  /// debounce this).
  void savePosition(String path, ReadingPosition position) {
    _positions[path] = position;
    notifyListeners();
    _writePositions();
  }

  void forgetPositions() {
    _positions.clear();
    notifyListeners();
    _writePositions();
  }

  void addOpened(String path) {
    opened
      ..remove(path)
      ..insert(0, path);
    notifyListeners();
  }

  Future<void> _readPositions() async {
    try {
      final saved = jsonDecode(await _positionsFile.readAsString()) as Map<String, Object?>;
      saved.forEach((path, position) {
        if (position is Map<String, Object?>) _positions[path] = position;
      });
    } on Object {
      // No positions yet, or an unreadable file: start afresh.
    }
  }

  Future<void> _writePositions() async {
    try {
      await _positionsFile.writeAsString(jsonEncode(_positions));
    } on FileSystemException {
      // Positions are a convenience.
    }
  }
}

String fileName(String path) => path.split(Platform.pathSeparator).last;
