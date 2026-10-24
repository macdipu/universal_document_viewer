import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/testing.dart';

/// Set (`--dart-define=THUMBNAIL_SAMPLES=/some/dir`) to save each format's
/// thumbnail there for a look, drawn with Roboto instead of the test font.
const _samplesDir = String.fromEnvironment('THUMBNAIL_SAMPLES');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('thumbnails_test');
    if (_samplesDir.isNotEmpty) await _loadRoboto();
  });
  tearDownAll(() => temp.delete(recursive: true));

  String file(String name, List<int> bytes) {
    final path = '${temp.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  /// Renders [path] at [width] and returns the PNG's pixel size.
  Future<(int, int)> renderSize(String path, {int width = 160, String? sample}) async {
    final png = await DocumentThumbnails.render(path, width: width);
    expect(png, isNotNull, reason: path);
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'PNG signature');
    if (_samplesDir.isNotEmpty && sample != null) {
      Directory(_samplesDir).createSync(recursive: true);
      File('$_samplesDir/$sample').writeAsBytesSync(png);
    }
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final size = (frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  test('PDF: page 1 at the page shape (US Letter)', () async {
    expect(await renderSize('test/fixtures/pdf/features.pdf', width: 120, sample: 'pdf.png'), (120, 155));
  });

  test('Word: page 1 of the print layout, at the section page size', () async {
    final (width, height) = await renderSize('test/fixtures/word/features.docx', sample: 'word.png');
    expect(width, 160);
    // Letter (11/8.5) or A4 (1.414) portrait.
    expect(height / width, inInclusiveRange(1.28, 1.42));

    final landscape = file(
      'wide.docx',
      buildDocx('<w:p><w:r><w:t>Wide</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="15840" w:h="12240"/></w:sectPr>'),
    );
    final (_, wideHeight) = await renderSize(landscape);
    expect(wideHeight, closeTo(160 * 12240 / 15840, 1));
  });

  test('Excel: the first visible sheet on a 3:4 card', () async {
    expect(await renderSize('test/fixtures/sheets/features.xlsx', sample: 'excel.png'), (160, 214));
    final hiddenFirst = file(
      'hidden.xlsx',
      buildXlsx([
        const XlsxTestSheet('Hidden', {'A1': 'secret'}, state: 'hidden'),
        const XlsxTestSheet('Shown', {'A1': XlsxTestCell('Total', bold: true, fill: 'FFC000'), 'B1': 42}),
      ]),
    );
    expect(await renderSize(hiddenFirst), (160, 214));
  });

  test('Excel: a large workbook still gets a thumbnail', () async {
    expect(await renderSize('test/fixtures/sheets/large.xlsx'), (160, 214));
  });

  test('CSV: the top-left cells on a 3:4 card', () async {
    final csv = file('data.csv', [
      for (final line in ['Region,Units,Price', 'North,120,9.99', 'South,80,12.50', 'East,"1,024",3.10'])
        ...'$line\n'.codeUnits,
    ]);
    expect(await renderSize(csv, sample: 'csv.png'), (160, 214));
  });

  test('PowerPoint: slide 1 in the slide shape, picture included', () async {
    final png = _solidPng(40, 20, 30, 120, 220);
    final widescreen = file(
      'deck.pptx',
      buildPptx(
        [
          titleShape('Quarterly review') + bodyShape([('Revenue up 12%', 0), ('Two new markets', 1)]) + picture('rIdImg'),
          titleShape('Second slide'),
        ],
        media: {'image1.png': png},
        slideRels: {0: '<Relationship Id="rIdImg" Type="image" Target="../media/image1.png"/>'},
      ),
    );
    expect(await renderSize(widescreen, sample: 'powerpoint.png'), (160, 90));
    final standard = file('standard.pptx', buildPptx([titleShape('4:3')], slideSize: (9144000, 6858000)));
    expect(await renderSize(standard), (160, 120));
  });

  test('Text: the first lines on an A4 page', () async {
    final text = file('notes.txt', [
      for (var i = 1; i <= 200; i++) ...'Line $i of the meeting notes, long enough to wrap on the page.\n'.codeUnits,
    ]);
    expect(await renderSize(text, sample: 'text.png'), (160, 227));
  });

  group('resumed: the page a saved position is on', () {
    /// [path]'s thumbnail at [position], which must differ from its first
    /// page's; a position past the end of the file must give the first.
    Future<void> expectResumed(String path, ReadingPosition position, ReadingPosition pastTheEnd) async {
      final first = await DocumentThumbnails.render(path, width: 160);
      final resumed = await DocumentThumbnails.render(path, width: 160, position: position);
      expect(first, isNotNull, reason: path);
      expect(resumed, isNotNull, reason: path);
      expect(resumed, isNot(first), reason: '$path at $position');
      expect(await DocumentThumbnails.render(path, width: 160, position: pastTheEnd), first, reason: '$path at $pastTheEnd');
    }

    test('PDF: the saved page', () async {
      await expectResumed(
        'test/fixtures/pdf/features.pdf',
        {PositionKeys.pageNumber: 3, PositionKeys.pageCount: 4},
        {PositionKeys.pageNumber: 99},
      );
    });

    test('PowerPoint: the saved slide', () async {
      final deck = file('resume.pptx', buildPptx([titleShape('One'), titleShape('Second slide, a longer title')]));
      await expectResumed(deck, {PositionKeys.slideIndex: 1}, {PositionKeys.slideIndex: 5});
    });

    test('Excel and CSV: the saved sheet from its saved top-left cell', () async {
      final workbook = file(
        'resume.xlsx',
        buildXlsx([
          const XlsxTestSheet('First', {'A1': 'a'}),
          const XlsxTestSheet('Second', {'A1': XlsxTestCell('Total', bold: true, fill: 'FFC000')}),
        ]),
      );
      await expectResumed(workbook, {PositionKeys.sheetIndex: 1}, {PositionKeys.sheetIndex: 7});
      final far = file(
        'far.xlsx',
        buildXlsx([
          const XlsxTestSheet('Only', {'A1': 'a', 'D60': XlsxTestCell('Here', fill: 'FFC000')}),
        ]),
      );
      final top = await DocumentThumbnails.render(far, width: 160);
      final scrolled = await DocumentThumbnails.render(
        far,
        width: 160,
        position: {PositionKeys.sheetIndex: 0, PositionKeys.row: 55, PositionKeys.column: 2},
      );
      expect(scrolled, isNot(top));

      final csv = file('resume.csv', [
        for (var i = 1; i <= 300; i++) ...(i < 200 ? 'a,b\n' : 'a much longer cell,another long one,third\n').codeUnits,
      ]);
      final csvTop = await DocumentThumbnails.render(csv, width: 160);
      final csvResumed = await DocumentThumbnails.render(csv, width: 160, position: {PositionKeys.row: 250});
      expect(csvResumed, isNotNull);
      expect(csvResumed, isNot(csvTop));
    });

    test('Word: the print-layout page holding the saved paragraph', () async {
      // 120 short paragraphs fill a few pages; the long ones after them
      // look different from page 1.
      final body = StringBuffer();
      for (var i = 0; i < 120; i++) {
        body.write('<w:p><w:r><w:t>Short $i</w:t></w:r></w:p>');
      }
      for (var i = 0; i < 40; i++) {
        body.write('<w:p><w:r><w:t>${'A much longer paragraph that wraps over several lines. ' * 4}</w:t></w:r></w:p>');
      }
      final document = file('resume.docx', buildDocx(body.toString()));
      await expectResumed(document, {PositionKeys.paragraph: 130}, {PositionKeys.paragraph: 10000});
      // Saved before paragraphs were reported: page 1.
      expect(
        await DocumentThumbnails.render(document, width: 160, position: {PositionKeys.scrollOffset: 900.0}),
        await DocumentThumbnails.render(document, width: 160),
      );
    });

    test('Word: past how far it paginates, the page starting at the paragraph', () async {
      final body = StringBuffer();
      for (var i = 0; i < 1300; i++) {
        body.write('<w:p><w:r><w:t>${i < 1200 ? 'Short $i' : 'A much longer paragraph that wraps over several lines. ' * 4}</w:t></w:r></w:p>');
      }
      final document = file('long.docx', buildDocx(body.toString()));
      final first = await DocumentThumbnails.render(document, width: 160);
      final resumed = await DocumentThumbnails.render(document, width: 160, position: {PositionKeys.paragraph: 1250});
      expect(resumed, isNotNull);
      expect(resumed, isNot(first));
    });

    test('Text: the lines from the saved one on', () async {
      final text = file('resume.txt', [
        for (var i = 1; i <= 2000; i++) ...(i < 1500 ? 'Short $i\n' : 'A much longer line that wraps on the page, line $i.\n').codeUnits,
      ]);
      await expectResumed(text, {PositionKeys.line: 1600, PositionKeys.scrollOffset: 32000.0}, {PositionKeys.line: 99999});
    });
  });

  group('null, never an error, when there is nothing to show', () {
    test('damaged, password-protected and missing files', () async {
      expect(await DocumentThumbnails.render('test/fixtures/pdf/broken.pdf', width: 160), isNull);
      expect(await DocumentThumbnails.render('test/fixtures/pdf/encrypted.pdf', width: 160), isNull);
      expect(await DocumentThumbnails.render(file('junk.docx', [1, 2, 3, 4]), width: 160), isNull);
      expect(await DocumentThumbnails.render(file('junk.xlsx', [1, 2, 3, 4]), width: 160), isNull);
      expect(await DocumentThumbnails.render(file('junk.pptx', [1, 2, 3, 4]), width: 160), isNull);
      expect(await DocumentThumbnails.render('${temp.path}/missing.pdf', width: 160), isNull);
    });

    test('unsupported types and bad widths', () async {
      expect(await DocumentThumbnails.render(file('old.doc', [1, 2, 3]), width: 160), isNull);
      expect(await DocumentThumbnails.render('test/fixtures/pdf/features.pdf', width: 0), isNull);
    });

    test('binary text and files too large for their reader', () async {
      expect(await DocumentThumbnails.render(file('binary.txt', [0x41, 0, 0x42, 0]), width: 160), isNull);
      for (final name in ['huge.txt', 'huge.csv']) {
        final path = file(name, const []);
        // Sparse: sized past the readers' 20 MB ceiling without writing it.
        (File(path).openSync(mode: FileMode.write)..truncateSync(21 * 1024 * 1024)).closeSync();
        expect(await DocumentThumbnails.render(path, width: 160), isNull, reason: name);
      }
    });
  });
}

/// Roboto from the Flutter SDK, under the families the samples ask for, so
/// saved samples show letters rather than the test font's boxes.
Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  if (!File('$fonts/Roboto-Regular.ttf').existsSync()) return;
  Future<ByteData> load(String name) async => ByteData.sublistView(Uint8List.fromList(File('$fonts/$name').readAsBytesSync()));
  for (final family in ['Roboto', 'Calibri', 'Calibri Light', 'Cambria', 'Arial', 'Times New Roman', 'Aptos']) {
    final loader = FontLoader(family)
      ..addFont(load('Roboto-Regular.ttf'))
      ..addFont(load('Roboto-Bold.ttf'))
      ..addFont(load('Roboto-Italic.ttf'));
    await loader.load();
  }
}

/// A [width] x [height] PNG of one RGB colour, written by hand (8-bit RGB,
/// no filtering) so the test needs no imaging package.
List<int> _solidPng(int width, int height, int r, int g, int b) {
  List<int> uint32(int value) => [value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF];
  List<int> chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    return [...uint32(data.length), ...body, ...uint32(getCrc32(body))];
  }

  final rows = [
    for (var y = 0; y < height; y++) ...[0, for (var x = 0; x < width; x++) ...[r, g, b]],
  ];
  return [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', [...uint32(width), ...uint32(height), 8, 2, 0, 0, 0]),
    ...chunk('IDAT', ZLibCodec().encode(rows)),
    ...chunk('IEND', const []),
  ];
}
