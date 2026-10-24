import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/word.dart';

String p(String text, {String props = '', String run = ''}) =>
    '<w:p><w:pPr>$props</w:pPr><w:r><w:rPr>$run</w:rPr><w:t xml:space="preserve">$text</w:t></w:r></w:p>';

List<WordParagraph> paragraphs(List<WordBlock> blocks) => blocks.whereType<WordParagraph>().toList();

void main() {
  group('python-docx fixture', () {
    late WordDocument doc;
    setUpAll(() => doc = DocxReader.read(File('test/fixtures/word/features.docx').readAsBytesSync()));
    WordParagraph find(String text) => paragraphs(doc.body).firstWhere((p) => p.plainText.contains(text));

    test('headings and run formatting', () {
      final heading = find('Quarterly Report');
      expect(heading.outlineLevel, 0);
      final runs = find('Plain').inlines.whereType<WordText>().toList();
      expect(runs.firstWhere((r) => r.text == 'bold').format.bold, isTrue);
      expect(runs.firstWhere((r) => r.text == 'italic').format.italic, isTrue);
      final red = runs.firstWhere((r) => r.text == 'red underline').format;
      expect(red.underline, UnderlineStyle.single);
      expect(red.color, 0xFFC00000);
      expect(red.size, 14);
    });

    test('links', () {
      final link = find('Visit').inlines.whereType<WordText>().firstWhere((r) => r.text == 'our site');
      expect(link.link, const WordLink(url: 'https://example.com/'));
    });

    test('alignment, tabs and line breaks keep all the text', () {
      expect(find('Centred').format.alignment, ParagraphAlignment.center);
      expect(find('left').plainText, 'left\tright\nsecond line');
    });

    test('lists are numbered from the document', () {
      expect(find('Apples').marker?.text, '•');
      expect(find('Pears').marker?.text, '•');
      expect([find('First').marker?.text, find('Second').marker?.text, find('Third').marker?.text], ['1.', '2.', '3.']);
    });

    test('tables: spans, vertical merges, borders', () {
      final table = doc.body.whereType<WordTable>().single;
      expect(table.columnWidths, hasLength(3));
      expect(table.rows, hasLength(3));
      final first = table.rows[0].cells;
      expect(first, hasLength(2));
      expect(first[0].columnSpan, 2);
      expect(paragraphs(first[0].blocks).first.plainText, 'wide');
      final tall = table.rows[1].cells[2];
      expect(tall.rowSpan, 2);
      expect(paragraphs(tall.blocks).first.plainText, 'tall');
      expect(table.rows[2].cells[2].covered, isTrue);
      expect(first[0].borders.top?.width, greaterThan(0), reason: 'Table Grid');
    });

    test('images', () {
      final image = paragraphs(doc.body).expand((p) => p.inlines).whereType<WordImage>().single;
      expect(image.width, closeTo(72, 0.1));
      expect(image.height, closeTo(36, 0.1));
      expect(doc.images[image.part], isNotNull);
    });

    test('page breaks, sections, headers and footers', () {
      expect(find('Before the break').inlines.whereType<WordBreak>().single.kind, BreakKind.page);
      expect(doc.sections, hasLength(2));
      expect(doc.body.whereType<WordSectionBreak>().single.sectionIndex, 0);
      expect(doc.sections[1].pageWidth, greaterThan(doc.sections[1].pageHeight));
      String text(List<WordBlock> blocks) => paragraphs(blocks).map((p) => p.plainText).join();
      expect(text(doc.sections[0].headers[HeaderFooterKind.defaultKind]!), 'Report header');
      expect(text(doc.sections[1].footers[HeaderFooterKind.defaultKind]!), 'Page footer', reason: 'inherited');
    });
  });

  group('built in memory', () {
    test('fields: results shown, instructions hidden, HYPERLINK fields link', () {
      final doc = DocxReader.read(buildDocx(
        '<w:p>'
        '<w:r><w:t xml:space="preserve">Page </w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>7</w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
        '<w:r><w:t xml:space="preserve"> see </w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText xml:space="preserve"> HYPERLINK "https://a.example" </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>here</w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
        '<w:fldSimple w:instr=" HYPERLINK \\l &quot;intro&quot; "><w:r><w:t>back</w:t></w:r></w:fldSimple>'
        '</w:p>',
      ));
      final paragraph = paragraphs(doc.body).single;
      expect(paragraph.plainText, 'Page 7 see hereback');
      final texts = paragraph.inlines.whereType<WordText>().toList();
      expect(texts.firstWhere((t) => t.text == 'here').link, const WordLink(url: 'https://a.example'));
      expect(texts.firstWhere((t) => t.text == 'back').link, const WordLink(anchor: 'intro'));
    });

    test('tracked changes show as accepted; hidden text is left out', () {
      final doc = DocxReader.read(buildDocx(
        '<w:p><w:r><w:t xml:space="preserve">kept </w:t></w:r>'
        '<w:ins><w:r><w:t>added</w:t></w:r></w:ins>'
        '<w:del><w:r><w:delText>removed</w:delText></w:r></w:del>'
        '<w:r><w:rPr><w:vanish/></w:rPr><w:t>secret</w:t></w:r></w:p>',
      ));
      expect(paragraphs(doc.body).single.plainText, 'kept added');
    });

    test('footnotes and endnotes: numbered by first reference', () {
      final doc = DocxReader.read(buildDocx(
        '<w:p><w:r><w:t>A</w:t></w:r><w:r><w:footnoteReference w:id="5"/></w:r>'
        '<w:r><w:t>B</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r>'
        '<w:r><w:endnoteReference w:id="1"/></w:r></w:p>',
        footnotes: '<w:footnote w:type="separator" w:id="-1"><w:p/></w:footnote>'
            '<w:footnote w:id="2"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> Second</w:t></w:r></w:p></w:footnote>'
            '<w:footnote w:id="5"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> First</w:t></w:r></w:p></w:footnote>',
        endnotes: '<w:endnote w:id="1"><w:p><w:r><w:endnoteRef/></w:r><w:r><w:t xml:space="preserve"> End</w:t></w:r></w:p></w:endnote>',
      ));
      final refs = paragraphs(doc.body).single.inlines.whereType<WordNoteReference>().toList();
      expect([for (final r in refs) r.label], ['1', '2', 'i']);
      expect(paragraphs(doc.footnotes['5']!).single.plainText, '1 First');
      expect(paragraphs(doc.footnotes['2']!).single.plainText, '2 Second');
      expect(paragraphs(doc.endnotes['1']!).single.plainText, 'i End');
    });

    test('styles: default paragraph style, basedOn, toggles, character styles', () {
      final doc = DocxReader.read(buildDocx(
        p('body') + p('heading', props: '<w:pStyle w:val="H"/>') +
            '<w:p><w:pPr><w:pStyle w:val="H"/></w:pPr><w:r><w:rPr><w:rStyle w:val="Strong"/></w:rPr><w:t>toggled</w:t></w:r></w:p>',
        styles: '<w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="20"/></w:rPr></w:rPrDefault></w:docDefaults>'
            '<w:style w:type="paragraph" w:default="1" w:styleId="Body"><w:rPr><w:color w:val="333333"/></w:rPr></w:style>'
            '<w:style w:type="paragraph" w:styleId="Base"><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
            '<w:style w:type="paragraph" w:styleId="H"><w:basedOn w:val="Base"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>'
            '<w:style w:type="character" w:styleId="Strong"><w:rPr><w:b/></w:rPr></w:style>',
      ));
      final [body, heading, toggled] = paragraphs(doc.body);
      final bodyRun = (body.inlines.single as WordText).format;
      expect(bodyRun.size, 10);
      expect(bodyRun.color, 0xFF333333, reason: 'w:default paragraph style, not "Normal"');
      final headingRun = (heading.inlines.single as WordText).format;
      expect(headingRun.bold, isTrue);
      expect(headingRun.size, 16);
      expect(heading.outlineLevel, 1);
      expect((toggled.inlines.single as WordText).format.bold, isFalse, reason: 'bold style XOR bold character style');
    });

    test('numbering: levels, templates, restarts, continuing lists', () {
      String item(String text, int numId, [int level = 0]) =>
          p(text, props: '<w:numPr><w:ilvl w:val="$level"/><w:numId w:val="$numId"/></w:numPr>');
      final doc = DocxReader.read(buildDocx(
        item('one', 1) + item('one.a', 1, 1) + item('one.b', 1, 1) + item('two', 1) + item('two.a', 1, 1) +
            p('break') + item('three', 1) + item('restart', 2),
        numbering: '<w:abstractNum w:abstractNumId="0">'
            '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>'
            '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2)"/></w:lvl>'
            '</w:abstractNum>'
            '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
            '<w:num w:numId="2"><w:abstractNumId w:val="0"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>',
      ));
      expect([for (final p in paragraphs(doc.body)) p.marker?.text],
          ['1.', '1.a)', '1.b)', '2.', '2.a)', null, '3.', '1.']);
    });

    test('not a document', () {
      expect(() => DocxReader.read(buildXlsx(const [XlsxTestSheet('S', {'A1': 'x'})])), throwsA(isA<DocxFormatException>()));
    });
  });

  group('malformed or hostile input', () {
    const drawingNs = 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"';
    const vmlNs = 'xmlns:v="urn:schemas-microsoft-com:vml"';
    const relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

    /// A paragraph holding a text box holding [inner], nested [depth] deep.
    String drawingBoxes(int depth, String inner) => depth == 0
        ? inner
        : '<w:p><w:r><w:drawing><wp:inline $drawingNs><wp:extent cx="1" cy="1"/><a:graphic><a:graphicData>'
            '<wps:wsp><wps:txbx><w:txbxContent>${drawingBoxes(depth - 1, inner)}</w:txbxContent></wps:txbx></wps:wsp>'
            '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';
    String vmlBoxes(int depth, String inner) => depth == 0
        ? inner
        : '<w:p><w:r><w:pict><v:shape $vmlNs><v:textbox><w:txbxContent>${vmlBoxes(depth - 1, inner)}'
            '</w:txbxContent></v:textbox></v:shape></w:pict></w:r></w:p>';
    int count(WordDocument doc, String text) => paragraphs(doc.body).where((p) => p.plainText == text).length;

    test('nested text boxes are read once each, and a deep nest is cut off quickly', () {
      for (final boxes in [drawingBoxes, vmlBoxes]) {
        expect(count(DocxReader.read(buildDocx(boxes(2, p('leaf')))), 'leaf'), 1);
        final stopwatch = Stopwatch()..start();
        final deep = DocxReader.read(buildDocx(boxes(40, p('leaf'))));
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(count(deep, 'leaf'), 0, reason: 'past the nesting cap');
      }
    });

    test('table spans and skipped columns are kept within the grid', () {
      String table(String span, {String before = '0'}) =>
          '<w:tbl><w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>'
          '<w:tr><w:trPr><w:gridBefore w:val="$before"/></w:trPr>'
          '<w:tc><w:tcPr><w:gridSpan w:val="$span"/></w:tcPr><w:p/></w:tc><w:tc><w:p/></w:tc></w:tr></w:tbl>';
      int firstSpan(String xml) =>
          (DocxReader.read(buildDocx(xml)).body.single as WordTable).rows.single.cells.first.columnSpan;
      expect(firstSpan(table('-1')), 1);
      expect(firstSpan(table('0')), 1);
      expect(firstSpan(table('3000000')), 2);
      expect(firstSpan(table('3000000', before: '-5')), 2);
      expect(firstSpan(table('3000000', before: '99999999')), 2);
      // Without a grid, capped at Word's column limit.
      const noGrid = '<w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="3000000"/></w:tcPr><w:p/></w:tc></w:tr></w:tbl>';
      expect(firstSpan(noGrid), 64);
    });

    String listItem(String level) => '<w:p><w:pPr><w:numPr><w:ilvl w:val="$level"/><w:numId w:val="1"/></w:numPr></w:pPr>'
        '<w:r><w:t>x</w:t></w:r></w:p>';
    String list(String level, {String start = '1', String format = 'decimal', String text = '%1.', String num = ''}) =>
        '<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="$level"><w:start w:val="$start"/><w:numFmt w:val="$format"/>'
        '<w:lvlText w:val="$text"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/>$num</w:num>';
    String? marker(String body, String numbering) =>
        paragraphs(DocxReader.read(buildDocx(body, numbering: numbering)).body).first.marker?.text;

    test('numbering levels outside 0-8 are ignored', () {
      expect(marker(listItem('9'), list('9')), isNull);
      expect(marker(listItem('-1'), list('-1')), isNull);
      expect(marker(listItem('0'), list('0', text: '%0.%1')), '.1');
      expect(
        marker(listItem('0'), list('0', num: '<w:lvlOverride w:ilvl="-3"><w:startOverride w:val="5"/></w:lvlOverride>'
            '<w:lvlOverride w:ilvl="12"><w:startOverride w:val="5"/></w:lvlOverride>')),
        '1.',
      );
    });

    test('list numbers are bounded, so letter numbering stays short', () {
      expect(marker(listItem('0'), list('0', start: '100000000', format: 'lowerLetter'))!.length, lessThan(1300));
      final overridden = marker(listItem('0'),
          list('0', num: '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="-100000000"/></w:lvlOverride>'));
      expect(overridden, '0.');
    });

    test('a footnote that refers to another footnote', () {
      final doc = DocxReader.read(buildDocx(
        '<w:p><w:r><w:footnoteReference w:id="1"/></w:r></w:p>',
        footnotes: '<w:footnote w:id="1"><w:p><w:r><w:t>one</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>'
            '</w:footnote><w:footnote w:id="2"><w:p><w:r><w:t>two</w:t></w:r></w:p></w:footnote>',
      ));
      expect(doc.footnotes.keys, ['1', '2']);
      expect(paragraphs(doc.footnotes['2']!).single.plainText, 'two');
    });

    test('only the body ends sections: a header referencing itself, a text box section', () {
      final header = '<?xml version="1.0"?>'
          '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="$relNs">'
          '<w:p><w:pPr><w:sectPr><w:headerReference w:type="default" r:id="rH"/></w:sectPr></w:pPr>'
          '<w:r><w:t>head</w:t></w:r></w:p></w:hdr>';
      final headerRels = '<?xml version="1.0"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rH" Type="$relNs/header" Target="header1.xml"/></Relationships>';
      final doc = DocxReader.read(buildDocx(
        drawingBoxes(1, '<w:p><w:pPr><w:sectPr/></w:pPr></w:p>') +
            '<w:p><w:r><w:t>body</w:t></w:r></w:p><w:sectPr><w:headerReference w:type="default" r:id="rH"/></w:sectPr>',
        relationships: '<Relationship Id="rH" Type="$relNs/header" Target="header1.xml"/>',
        media: {'header1.xml': header.codeUnits, '_rels/header1.xml.rels': headerRels.codeUnits},
      ));
      expect(doc.sections, hasLength(1));
      expect(doc.body.whereType<WordSectionBreak>(), isEmpty);
      expect(paragraphs(doc.sections.single.headers[HeaderFooterKind.defaultKind]!).single.plainText, 'head');
    });

    test('non-finite and out-of-range page sizes fall back to sane ones', () {
      WordSection section(String sectPr) =>
          DocxReader.read(buildDocx('<w:p/><w:sectPr>$sectPr</w:sectPr>')).sections.single;
      final infinite = section('<w:pgSz w:w="Infinity" w:h="NaN"/><w:pgMar w:left="-Infinity" w:top="NaN"/>');
      expect([infinite.pageWidth, infinite.pageHeight, infinite.marginLeft, infinite.marginTop], [612, 792, 72, 72]);
      final huge = section('<w:pgSz w:w="99999999" w:h="1"/><w:pgMar w:left="-1440" w:right="99999999"/>');
      expect([huge.pageWidth, huge.pageHeight, huge.marginLeft, huge.marginRight], [1584, 36, 72, 1584]);
    });
  });
}
