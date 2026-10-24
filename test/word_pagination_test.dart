import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/docx.dart';
import 'package:universal_document_viewer/src/word/word_pagination.dart';
import 'package:universal_document_viewer/src/word/word_paragraph_styler.dart';
import 'package:universal_document_viewer/testing.dart';

String para(String text, {String props = ''}) =>
    '<w:p><w:pPr>$props</w:pPr><w:r><w:t xml:space="preserve">$text</w:t></w:r></w:p>';

const _lorem = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore '
    'et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip. ';

void main() {
  WordPagination paginate(WordDocument document) => WordPaginator(
        WordDocumentLayout(document),
        WordMeasurer(WordParagraphStyler(scheme: const ColorScheme.light(), linkColor: 0xFF0563C1)),
      ).paginate();

  /// All text on the pages, pieces of split paragraphs joined back up.
  String pageText(WordPagination pagination) {
    final out = StringBuffer();
    for (final page in pagination.pages) {
      for (final entry in page.entries) {
        final block = entry.block;
        if (block is WordParagraph) {
          if (entry.textOffset == 0 && out.isNotEmpty) out.write('|');
          out.write(block.plainText);
        } else if (block is WordTable) {
          out.write('|[table ${block.rows.length}]');
        }
      }
    }
    return out.toString();
  }

  testWidgets('long text flows over pages with nothing lost or repeated', (tester) async {
    final document = DocxReader.read(buildDocx([for (var i = 0; i < 40; i++) para('$i $_lorem$_lorem')].join()));
    final pagination = paginate(document);
    expect(pagination.pages.length, greaterThan(3));
    expect(pageText(pagination), [for (var i = 0; i < 40; i++) '$i $_lorem$_lorem'].join('|'));
    final split = pagination.pages.expand((p) => p.entries).where((e) => e.textOffset > 0);
    expect(split, isNotEmpty, reason: 'some paragraph crossed a page edge');
  });

  testWidgets('page breaks, pageBreakBefore and sections start new pages', (tester) async {
    final document = DocxReader.read(buildDocx(
      '${para('one')}<w:p><w:r><w:t>two</w:t><w:br w:type="page"/><w:t>three</w:t></w:r></w:p>'
      '${para('four', props: '<w:pageBreakBefore/>')}'
      '<w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:pPr><w:r><w:t>five</w:t></w:r></w:p>'
      '${para('wide')}<w:sectPr><w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/></w:sectPr>',
    ));
    final pages = paginate(document).pages;
    String text(WordPage page) => page.entries.map((e) => (e.block as WordParagraph?)?.plainText ?? '').join(',');
    expect(pages.map(text).toList(), ['one,two', 'three', 'four,five', 'wide']);
    expect(pages.last.width, greaterThan(pages.last.height));
  });

  testWidgets('long tables split between rows and repeat header rows', (tester) async {
    String row(String text, {bool header = false}) =>
        '<w:tr>${header ? '<w:trPr><w:tblHeader/></w:trPr>' : ''}<w:tc><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:tc></w:tr>';
    final document = DocxReader.read(buildDocx(
      '<w:tbl><w:tblGrid><w:gridCol w:w="5000"/></w:tblGrid>${row('Head', header: true)}'
      '${[for (var i = 0; i < 120; i++) row('Row $i')].join()}</w:tbl>',
    ));
    final pages = paginate(document).pages;
    expect(pages.length, greaterThan(1));
    final tables = [for (final page in pages) page.entries.single.block as WordTable];
    for (final table in tables) {
      expect((table.rows.first.cells.single.blocks.single as WordParagraph).plainText, 'Head');
    }
    final dataRows = tables.expand((t) => t.rows.skip(1)).length;
    expect(dataRows, 120);
  });

  testWidgets('pages render within the space they were measured for', (tester) async {
    final bytes = buildDocx(
      [
        for (var i = 0; i < 30; i++) para('$i $_lorem', props: i.isEven ? '<w:spacing w:after="240"/>' : '<w:jc w:val="both"/>'),
        '<w:tbl><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>',
        for (var i = 0; i < 30; i++)
          '<w:tr><w:tc><w:p><w:r><w:t>$_lorem</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>$i</w:t></w:r></w:p></w:tc></w:tr>',
        '</w:tbl>',
        '<w:sectPr><w:footerReference w:type="default" r:id="rIdF"/></w:sectPr>',
      ].join(),
      relationships: '<Relationship Id="rIdF" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>',
      media: {
        'footer1.xml': '<?xml version="1.0"?><w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                '<w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r><w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t></w:r></w:fldSimple>'
                '<w:r><w:t xml:space="preserve"> of </w:t></w:r><w:fldSimple w:instr=" NUMPAGES "><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p></w:ftr>'
            .codeUnits,
      },
    );
    final controller = WordDocumentController(initialPosition: const {'view_mode': 'paged'});
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.load(bytes));
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WordDocumentView(controller: controller))));
    await tester.pump();
    final pagination = WordPaginator(
      controller.layout!,
      WordMeasurer(WordParagraphStyler(scheme: const ColorScheme.light(surface: Colors.white, onSurface: Colors.black), linkColor: 0xFF0563C1)),
    ).paginate();
    expect(pagination.pages.length, greaterThan(2));
    expect(find.textContaining('Page 1 of ${pagination.pages.length}', findRichText: true), findsOneWidget);
    // Each built page's body column is no taller than its page body.
    for (final column in tester.widgetList<Column>(find.byType(Column))) {
      final element = find.byWidget(column).evaluate().first;
      final box = element.renderObject! as RenderBox;
      final page = pagination.pages.first;
      if (column.children.length > 3 && box.size.width.round() == page.bodyWidth.round()) {
        expect(box.size.height, lessThanOrEqualTo(page.bodyHeight + 1));
      }
    }
  });
}
