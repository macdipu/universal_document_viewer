import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';
import 'package:universal_document_viewer/src/pdf/pdf_controller.dart' show probePdfTextLayer;

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

  group('DocumentViewerStrings.searchStatus', () {
    String label({
      String query = 'x',
      bool isSearching = false,
      int matchCount = 0,
      int currentMatch = -1,
      bool hasSearchableText = true,
    }) => const DocumentViewerStrings().searchStatus(
      DocumentSearchState(
        query: query,
        matchCount: matchCount,
        currentMatch: currentMatch,
        isSearching: isSearching,
        hasSearchableText: hasSearchableText,
      ),
    );

    test('empty without a query', () => expect(label(query: ''), ''));
    test('searching', () => expect(label(isSearching: true), 'Searching…'));
    test('zero matches in a document with text', () => expect(label(), 'No matches'));
    test(
      'zero matches in a scanned PDF (BRD line 1087)',
      () => expect(label(hasSearchableText: false), 'No searchable text found.'),
    );
    test('match position', () => expect(label(matchCount: 4, currentMatch: 1), '2 of 4'));
  });
}
