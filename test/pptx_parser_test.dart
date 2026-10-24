import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/slides.dart';

import 'package:universal_document_viewer/testing.dart';

void main() {
  test('reads slides in presentation order, not file-name order', () {
    final bytes = buildPptx([titleShape('First'), titleShape('Second'), titleShape('Third')]);

    final slides = PptxParser.parse(bytes).slides;

    expect(slides.map((s) => s.title), ['First', 'Second', 'Third']);
  });

  test('reads the slide size, 16:9 when the file has none', () {
    final standard = PptxParser.parse(buildPptx([titleShape('A')], slideSize: (9144000, 6858000)));
    expect((standard.slideWidth, standard.slideHeight), (9144000, 6858000));
    final unsized = PptxParser.parse(buildPptx([titleShape('A')]));
    expect((unsized.slideWidth, unsized.slideHeight), (12192000, 6858000));
  });

  test('separates the title from body paragraphs and keeps bullet levels', () {
    final bytes = buildPptx([
      titleShape('Agenda') + bodyShape([('Intro', 0), ('Details', 1), ('Wrap up', 0)]),
    ]);

    final slide = PptxParser.parse(bytes).slides.single;

    expect(slide.title, 'Agenda');
    final paragraphs = slide.blocks.cast<PptxParagraph>();
    expect(paragraphs.map((p) => p.text), ['Intro', 'Details', 'Wrap up']);
    expect(paragraphs.map((p) => p.level), [0, 1, 0]);
  });

  test('reads tables as rows of cell text', () {
    final bytes = buildPptx([
      tableFrame([
        ['Name', 'Score'],
        ['Ada', '10'],
      ]),
    ]);

    final table = PptxParser.parse(bytes).slides.single.blocks.single as PptxTable;

    expect(table.rows, [
      ['Name', 'Score'],
      ['Ada', '10'],
    ]);
  });

  test('loads pictures through the slide relationships, skipping formats Flutter cannot draw', () {
    final png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
    final bytes = buildPptx(
      [picture('rIdImg') + picture('rIdVector')],
      media: {'image1.png': png, 'image2.emf': [1, 2]},
      slideRels: {
        0: '<Relationship Id="rIdImg" Type="image" Target="../media/image1.png"/>'
            '<Relationship Id="rIdVector" Type="image" Target="../media/image2.emf"/>',
      },
    );

    final blocks = PptxParser.parse(bytes).slides.single.blocks;

    expect(blocks, hasLength(1));
    expect((blocks.single as PptxImage).bytes, png);
  });

  test('slide text covers title, paragraphs and table cells for search', () {
    final bytes = buildPptx([
      titleShape('Quarterly') + bodyShape([('Revenue grew', 0)]) + tableFrame([
            ['Region', 'North'],
          ]),
    ]);

    final text = PptxParser.parse(bytes).slides.single.text;

    expect(text, contains('Quarterly'));
    expect(text, contains('Revenue grew'));
    expect(text, contains('North'));
  });

  test('keeps non-ASCII text intact', () {
    final bytes = buildPptx([titleShape('Résumé – 東京')]);

    expect(PptxParser.parse(bytes).slides.single.title, 'Résumé – 東京');
  });

  test('rejects bytes that are not a PowerPoint package', () {
    expect(() => PptxParser.parse(Uint8List.fromList([1, 2, 3, 4])), throwsA(isA<PptxFormatException>()));
  });
}
