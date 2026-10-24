import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/slides.dart';
import 'package:universal_document_viewer/src/engines/ooxml/opc_package.dart';
import 'package:universal_document_viewer/src/thumbnails/text_thumbnail_renderer.dart';
import 'package:universal_document_viewer/src/thumbnails/thumbnail_sources.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/text.dart';

/// [zip] with the uncompressed size [name]'s local and central directory
/// headers declare rewritten to [size] - the forged entry a zip bomb uses to
/// slip past a check of declared sizes.
Uint8List forgeDeclaredSize(Uint8List zip, String name, int size) {
  final bytes = Uint8List.fromList(zip);
  final data = ByteData.sublistView(bytes);
  final wanted = utf8.encode(name);
  bool nameAt(int at, int length) =>
      length == wanted.length && at + length <= bytes.length && _sameBytes(bytes, at, wanted);
  for (var i = 0; i + 46 <= bytes.length; i++) {
    switch (data.getUint32(i, Endian.little)) {
      case 0x04034b50 when nameAt(i + 30, data.getUint16(i + 26, Endian.little)):
        data.setUint32(i + 22, size, Endian.little);
      case 0x02014b50 when nameAt(i + 46, data.getUint16(i + 28, Endian.little)):
        data.setUint32(i + 24, size, Endian.little);
    }
  }
  return bytes;
}

bool _sameBytes(Uint8List bytes, int at, List<int> wanted) {
  for (var j = 0; j < wanted.length; j++) {
    if (bytes[at + j] != wanted[j]) return false;
  }
  return true;
}

/// A file [length] bytes long without writing them: sparse where the file
/// system allows, so a test can be past a size ceiling cheaply.
File sparseFile(String path, int length) {
  final handle = File(path).openSync(mode: FileMode.write)..truncateSync(length);
  handle.closeSync();
  return File(path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('kit-hardening-'));
  tearDown(() => temp.delete(recursive: true));

  group('a part inflating past its declared size', () {
    const image = 'ppt/media/big.png';
    Uint8List forgedDeck() => forgeDeclaredSize(
          buildPptx(
            [titleShape('Bomb') + picture('rIdImg')],
            media: {'big.png': Uint8List(4 * 1024 * 1024)},
            slideRels: {0: '<Relationship Id="rIdImg" Type="image" Target="../media/big.png"/>'},
          ),
          image,
          10,
        );

    test('passes the guard, which only sees declared sizes', () {
      expect(ZipSafetyGuard.check(forgedDeck()), ZipSafetyResult.safe);
    });

    test('is refused by OpcPackage, not inflated', () {
      final package = OpcPackage.decode(forgedDeck());
      expect(() => package.readBytes(image), throwsA(isA<OpcFormatException>()));
      expect(package.readText('ppt/presentation.xml'), contains('sldId'));
    });

    test('leaves its picture out of the deck, not the slide', () {
      final slide = PptxParser.parse(forgedDeck()).slides.single;
      expect(slide.title, 'Bomb');
      expect(slide.blocks, isEmpty);
    });
  });

  group('PowerPoint pictures', () {
    const rel = {0: '<Relationship Id="rIdImg" Type="image" Target="../media/big.png"/>'};

    test('a picture placed many times shares one buffer', () {
      final bytes = buildPptx([List.filled(400, picture('rIdImg')).join()],
          media: {'big.png': Uint8List(1024 * 1024)}, slideRels: rel);
      final images = PptxParser.parse(bytes).slides.single.blocks.whereType<PptxImage>().toList();
      expect(images, hasLength(400));
      expect(images.map((image) => identityHashCode(image.bytes)).toSet(), hasLength(1));
    });

    test('placements past maxPictures are left out', () {
      final bytes = buildPptx([List.filled(PptxParser.maxPictures + 5, picture('rIdImg')).join()],
          media: {'big.png': [1, 2, 3]}, slideRels: rel);
      expect(PptxParser.parse(bytes).slides.single.blocks, hasLength(PptxParser.maxPictures));
    });

    test('parseSlide reads one slide, slide 1 for one the deck lacks', () {
      final bytes = buildPptx([titleShape('One'), titleShape('Two'), titleShape('Three')]);
      final second = PptxParser.parseSlide(bytes, 1);
      expect((second.index, second.deck.slides.single.title), (1, 'Two'));
      final missing = PptxParser.parseSlide(bytes, 7);
      expect((missing.index, missing.deck.slides.single.title), (0, 'One'));
    });

    test('bullet levels are clamped to DrawingML 0-8', () {
      final bytes = buildPptx([bodyShape([('deep', 40), ('negative', -3), ('fine', 2)])]);
      final levels = PptxParser.parse(bytes).slides.single.blocks.cast<PptxParagraph>().map((p) => p.level);
      expect(levels, [8, 0, 2]);
    });
  });

  group('Office files over ZipSafetyGuard.maxFileBytes', () {
    test('get no thumbnail, without being read', () async {
      final path = sparseFile('${temp.path}/huge.pptx', ZipSafetyGuard.maxFileBytes + 1).path;
      expect(await DocumentThumbnails.render(path, width: 120), isNull);
    });
  });

  group('text thumbnails', () {
    test('cut a long line, and the page, to what a page shows', () {
      final oneLine = TextThumbnailRenderer.linesFrom(Uint8List.fromList(List.filled(1 << 20, 0x61)), 0)!;
      expect(oneLine.length, 300);
      final manyLong = TextThumbnailRenderer.linesFrom(
        Uint8List.fromList(utf8.encode(List.filled(200, 'b' * 1000).join('\n'))),
        0,
      )!;
      expect(manyLong.length, lessThanOrEqualTo(8000));
    });

    test('a head with no line break ends on a UTF-8 character boundary', () async {
      final path = '${temp.path}/accents.txt';
      File(path).writeAsBytesSync(utf8.encode('é' * 100)); // 2 bytes each.
      for (final headBytes in [5, 6, 7]) {
        final head = (await readTextHead(path, maxBytes: 1 << 20, headBytes: headBytes))!;
        expect(utf8.decode(head), 'é' * (headBytes ~/ 2), reason: 'head $headBytes');
      }
      expect(utf8Boundary(Uint8List.fromList(utf8.encode('a€'))), 4);
      expect(utf8Boundary(Uint8List.fromList(utf8.encode('a€').sublist(0, 3))), 1);
      expect(utf8Boundary(Uint8List.fromList(utf8.encode('a😀').sublist(0, 4))), 1);
    });
  });

  test('TextLineMetrics.lineAt far into a long file stays cheap, then refines', () {
    final metrics = TextLineMetrics(
      lines: List.generate(200000, (i) => 'Line $i of a fairly ordinary text file with some words in it.'),
      style: const TextStyle(fontSize: 14),
      textScaler: TextScaler.noScaling,
      contentWidth: 360,
      wrap: true,
      verticalPadding: 4,
    );
    final stopwatch = Stopwatch()..start();
    final estimate = metrics.lineAt(metrics.offsetOf(1000) * 50);
    // Measuring every line up to it took seconds.
    expect(stopwatch.elapsedMilliseconds, lessThan(1500));
    // Rows are all alike here, so the average-height estimate is about right.
    expect(estimate, inInclusiveRange(48000, 52000));
    expect(metrics.lineAt(1e12), 199999);
    // Measured rows are still exact.
    expect(metrics.lineAt(metrics.offsetOf(700) + 1), 700);
  });
}
