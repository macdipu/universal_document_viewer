import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/pdf_reader/pdf_document_controller.dart';

// CR-OPENREADER-UX Phase 1 revision 1: the PDF zero-match label. The
// controller wiring needs a live PdfTextSearcher (unavailable here, see
// pdf_reader_controller_test.dart), so these cover the pure helpers it uses.

void main() {
  group('probePdfTextLayer', () {
    test('true as soon as a page has text, without loading later pages', () async {
      final loaded = <int>[];
      final pages = {1: '  \n', 2: 'Quarterly report', 3: 'never read'};
      final result = await probePdfTextLayer(3, (page) async {
        loaded.add(page);
        return pages[page];
      });
      expect(result, isTrue);
      expect(loaded, [1, 2]);
    });

    test('false when every page loaded and is blank (scanned PDF)', () async {
      expect(await probePdfTextLayer(2, (_) async => ' \t\n'), isFalse);
    });

    test('null when a blank document still has unloaded pages', () async {
      expect(await probePdfTextLayer(2, (page) async => page == 1 ? '' : null), isNull);
    });

    test('text on a loaded page wins over unloaded pages', () async {
      expect(await probePdfTextLayer(2, (page) async => page == 1 ? null : 'text'), isTrue);
    });
  });

  group('pdfSearchStatusLabel', () {
    String label(
            {bool hasPattern = true,
            bool isSearching = false,
            int matchCount = 0,
            int? currentIndex,
            bool? hasTextLayer}) =>
        pdfSearchStatusLabel(
          hasPattern: hasPattern,
          isSearching: isSearching,
          matchCount: matchCount,
          currentIndex: currentIndex,
          hasTextLayer: hasTextLayer,
        );

    test('empty without a query', () => expect(label(hasPattern: false), ''));
    test('searching', () => expect(label(isSearching: true), 'Searching…'));
    test('zero matches in a PDF with text', () => expect(label(hasTextLayer: true), 'No matches'));
    test('zero matches before the probe has an answer', () => expect(label(), 'No matches'));
    test('zero matches in a scanned PDF (BRD line 1087)',
        () => expect(label(hasTextLayer: false), 'No searchable text found.'));
    test('match position', () => expect(label(matchCount: 4, currentIndex: 1), '2 of 4 result(s)'));
  });
}
