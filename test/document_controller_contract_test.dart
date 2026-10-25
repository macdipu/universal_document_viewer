import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

/// One format's case for the [DocumentController] contract: how to make
/// its controller, a document with [needle] in it [occurrences] times, and
/// what [location] counts.
class _Format {
  const _Format(
    this.name,
    this.create,
    this.document, {
    required this.needle,
    required this.occurrences,
    required this.unit,
    this.zoomsWithoutView = true,
  });

  final String name;
  final DocumentController Function() create;
  final Uint8List Function() document;
  final String needle;
  final int occurrences;
  final DocumentUnit unit;

  /// PDF zoom lives in its view; without one there's nothing to zoom.
  final bool zoomsWithoutView;
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

final _formats = [
  _Format(
    'PDF',
    PdfController.new,
    () => File('test/fixtures/pdf/features.pdf').readAsBytesSync(),
    needle: 'the',
    occurrences: -1, // Counted from the engine below.
    unit: DocumentUnit.page,
    zoomsWithoutView: false,
  ),
  _Format(
    'Word',
    WordController.new,
    () => buildDocx(
      '<w:p><w:r><w:t>Apple and apple</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>No fruit here</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>An APPLE</w:t></w:r></w:p>',
    ),
    needle: 'apple',
    occurrences: 3,
    unit: DocumentUnit.percent,
  ),
  _Format(
    'Excel',
    SpreadsheetController.new,
    () => buildXlsx([
      const XlsxTestSheet('Fruit', {'A1': 'Apple', 'B1': 'Pear', 'A2': 'apple pie', 'B3': 'APPLE'}),
    ]),
    needle: 'apple',
    occurrences: 3, // Cells, as Excel's Find counts.
    unit: DocumentUnit.row,
  ),
  _Format(
    'CSV',
    SpreadsheetController.new,
    () => _utf8('Name,Fruit\nAnn,Apple\nBo,Pear\nCy,apple\n'),
    needle: 'apple',
    occurrences: 2,
    unit: DocumentUnit.row,
  ),
  _Format(
    'PowerPoint',
    () => SlidesController(parse: (bytes) async => PptxParser.parse(bytes)),
    () => buildPptx([
      titleShape('Apple') + bodyShape([('apple and APPLE', 0)]),
      titleShape('Pear'),
      titleShape('One apple'),
    ]),
    needle: 'apple',
    occurrences: 4,
    unit: DocumentUnit.slide,
  ),
  _Format(
    'Plain text',
    PlainTextController.new,
    () => _utf8('Apple and apple\nno fruit\nAPPLE'),
    needle: 'apple',
    occurrences: 3,
    unit: DocumentUnit.line,
  ),
];

/// Lets a background search (PDF) finish.
Future<void> _settled(DocumentController controller) async {
  for (var i = 0; i < 200 && controller.searchState.value.isSearching; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  for (final format in _formats) {
    group('${format.name} follows the DocumentController contract', () {
      late DocumentController controller;

      setUp(() => controller = format.create());
      tearDown(() => controller.dispose());

      test('starts idle, with no location and no search', () {
        expect(controller.status, DocumentStatus.idle);
        expect(controller.isLoaded, isFalse);
        expect(controller.location.value, DocumentLocation.none);
        expect(controller.searchState.value, DocumentSearchState.none);
      });

      test('loads: ready, located in its unit, with a position to save', () async {
        await controller.loadBytes(format.document());
        expect(controller.status, DocumentStatus.ready);
        expect(controller.error, isNull);
        expect(controller.isLoaded, isTrue);
        final location = controller.location.value;
        expect(location.unit, format.unit);
        expect(location.count, greaterThan(0));
        expect(controller.position, isNotEmpty);
        expect(jsonDecode(jsonEncode(controller.position)), controller.position, reason: 'JSON-safe');
      });

      test('a damaged file fails with a typed error', () async {
        await controller.loadBytes(Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0, 0xFF, 0xFE, 1, 2]));
        expect(controller.status, DocumentStatus.failed);
        expect(controller.error, isNotNull);
      });

      test('search counts occurrences, steps through them and wraps, and clears', () async {
        await controller.loadBytes(format.document());
        controller.search(format.needle);
        await _settled(controller);
        final state = controller.searchState.value;
        expect(state.query, format.needle);
        if (format.occurrences >= 0) {
          expect(state.matchCount, format.occurrences);
        } else {
          expect(state.matchCount, greaterThan(1));
        }
        expect(state.currentMatch, 0);
        controller.nextMatch();
        expect(controller.searchState.value.currentMatch, 1);
        controller.previousMatch();
        controller.previousMatch();
        expect(controller.searchState.value.currentMatch, state.matchCount - 1, reason: 'wraps round');
        controller.clearSearch();
        expect(controller.searchState.value.isActive, isFalse);
        expect(controller.searchState.value.matchCount, 0);
      });

      test('a search with no matches says so', () async {
        await controller.loadBytes(format.document());
        controller.search('zzzzqqqq');
        await _settled(controller);
        expect(controller.searchState.value.matchCount, 0);
        expect(controller.searchState.value.currentMatch, -1);
      });

      test('zoom stays within its limits', () async {
        await controller.loadBytes(format.document());
        expect(controller.zoom, 1);
        expect(controller.minZoom, lessThanOrEqualTo(1));
        expect(controller.maxZoom, greaterThan(1));
        if (!format.zoomsWithoutView) return;
        controller.zoomIn();
        expect(controller.zoom, greaterThan(1));
        for (var i = 0; i < 50; i++) {
          controller.zoomIn();
        }
        expect(controller.zoom, controller.maxZoom);
        expect(controller.canZoomIn, isFalse);
        for (var i = 0; i < 50; i++) {
          controller.zoomOut();
        }
        expect(controller.zoom, controller.minZoom);
        expect(controller.canZoomOut, isFalse);
        controller.setZoom(100);
        expect(controller.zoom, controller.maxZoom, reason: 'setZoom clamps');
      });
    });
  }
}
