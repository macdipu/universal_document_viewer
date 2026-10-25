// The package's import rules (doc/architecture.md), checked against the
// source so they can't drift.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every `lib/src` file with the `lib/src` files it imports or exports.
Map<String, List<String>> _imports() {
  final result = <String, List<String>>{};
  for (final file in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final targets = <String>[];
    for (final match in RegExp(r"^(?:import|export) '([^']+)'", multiLine: true).allMatches(file.readAsStringSync())) {
      final uri = match.group(1)!;
      if (uri.startsWith('package:universal_document_viewer/')) {
        targets.add(p.join('lib', uri.substring('package:universal_document_viewer/'.length)));
      } else if (!uri.contains(':')) {
        targets.add(p.normalize(p.join(p.dirname(file.path), uri)));
      } else {
        targets.add(uri);
      }
    }
    result[p.normalize(file.path)] = targets;
  }
  return result;
}

/// The module a `lib/src` path belongs to: `common`, `pdf`, `engines/word`...
String _module(String path) {
  final parts = p.split(p.relative(path, from: 'lib/src'));
  return parts.first == 'engines' ? '${parts[0]}/${parts[1]}' : parts.first;
}

const _formats = {'pdf', 'word', 'spreadsheet', 'slides', 'plain_text'};

void main() {
  final imports = _imports();

  List<String> violations(bool Function(String from, String to) broken) => [
    for (final MapEntry(key: file, value: targets) in imports.entries)
      for (final target in targets)
        if (broken(file, target)) '$file -> $target',
  ];

  bool isSrc(String target) => target.startsWith('lib/src/');

  test('common imports only common', () {
    expect(violations((f, t) => _module(f) == 'common' && isSrc(t) && _module(t) != 'common'), isEmpty);
  });

  test('engines import only engines and common, and no Flutter', () {
    expect(
      violations(
        (f, t) =>
            _module(f).startsWith('engines/') &&
            ((isSrc(t) && !_module(t).startsWith('engines/') && _module(t) != 'common') ||
                t.startsWith('package:flutter/')),
      ),
      isEmpty,
    );
  });

  test('the generic OOXML engine imports no format engine', () {
    expect(violations((f, t) => _module(f) == 'engines/ooxml' && isSrc(t) && _module(t) != 'engines/ooxml'), isEmpty);
  });

  test('a format module imports no other format, the viewer or thumbnails', () {
    expect(
      violations((f, t) {
        final from = _module(f);
        final to = isSrc(t) ? _module(t) : '';
        return _formats.contains(from) && to != from && (_formats.contains(to) || to == 'viewer' || to == 'thumbnails');
      }),
      isEmpty,
    );
  });

  test('the PDFium bindings are used only inside the PDFium engine', () {
    expect(violations((f, t) => t.endsWith('pdfium_bindings.g.dart') && _module(f) != 'engines/pdfium'), isEmpty);
  });

  test('production code never imports the test builders', () {
    expect(violations((f, t) => isSrc(t) && _module(t) == 'testing' && _module(f) != 'testing'), isEmpty);
  });
}
