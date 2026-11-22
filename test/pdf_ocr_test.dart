import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';
import 'package:universal_document_viewer/src/pdf/pdf_ocr.dart';
import 'package:universal_document_viewer/src/pdf/pdf_selection.dart';

const _features = 'test/fixtures/pdf/features.pdf';

class _FakeRecognizer extends TextRecognizer {
  _FakeRecognizer({this.available = true, this.lines, this.fail = false, this.gate});

  final bool available;
  final List<OcrLine>? lines;
  final bool fail;
  final Completer<void>? gate;
  final inputs = <OcrInput>[];

  @override
  bool get isAvailable => available;

  @override
  Future<OcrResult> recognize(OcrInput input) async {
    inputs.add(input);
    await gate?.future;
    if (fail) throw StateError('no model');
    return OcrResult(lines: lines ?? const [], detectedLanguage: 'en');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  group('the recognizer contract', () {
    test('a result knows its text and whether it is empty', () {
      const result = OcrResult(
        lines: [
          OcrLine(text: 'first', rect: Rect.fromLTWH(0, 0, 50, 10)),
          OcrLine(text: 'second', rect: Rect.fromLTWH(0, 20, 60, 10), confidence: 0.9),
        ],
      );
      expect(result.text, 'first\nsecond');
      expect(result.isEmpty, isFalse);
      expect(OcrResult.empty.isEmpty, isTrue);
      expect(
        const OcrResult(
          lines: [OcrLine(text: '  ', rect: Rect.zero)],
        ).isEmpty,
        isTrue,
      );
    });

    test('a recognizer does not detect the language unless it says so', () {
      expect(_FakeRecognizer().supportsAutoDetect, isFalse);
    });
  });

  group('rendering a page for OCR', () {
    test('gives a PNG of the page at the asked width', () async {
      final document = await PdfiumDocument.openFile(_features);
      final (png, width, height) = await document.renderPagePng(0, width: 800);
      expect(width, 800);
      expect(height, closeTo(800 * document.pageSizes[0].height / document.pageSizes[0].width, 1));
      // The PNG signature.
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      await expectLater(document.renderPagePng(99), throwsA(isA<PdfEngineException>()));
      await document.close();
    });
  });

  group('lines to page text', () {
    test('image pixels become page points', () {
      final lines = ocrLinesOnPage(
        const OcrResult(
          lines: [OcrLine(text: 'hello\nworld', rect: Rect.fromLTRB(100, 200, 300, 240))],
        ),
        imageSize: const Size(1000, 2000),
        pageSize: const Size(500, 1000),
      );
      expect(lines.single.text, 'hello world');
      expect(lines.single.rect, const Rect.fromLTRB(50, 100, 150, 120));
    });

    test('blank lines are dropped', () {
      final lines = ocrLinesOnPage(
        const OcrResult(
          lines: [OcrLine(text: ' ', rect: Rect.fromLTWH(0, 0, 10, 10))],
        ),
        imageSize: const Size(10, 10),
        pageSize: const Size(10, 10),
      );
      expect(lines, isEmpty);
    });

    test('a page with no text becomes the recognised lines, a character box each', () {
      final text = mergeOcr(const PdfPageText('', []), const [
        PdfOcrLine('ab', Rect.fromLTRB(0, 0, 20, 10)),
        PdfOcrLine('cd', Rect.fromLTRB(0, 20, 20, 30)),
      ]);
      expect(text.text, 'ab\r\ncd');
      expect(text.boxes, hasLength(text.text.length));
      expect(text.boxes[0], const Rect.fromLTRB(0, 0, 10, 10));
      expect(text.boxes[1], const Rect.fromLTRB(10, 0, 20, 10));
      expect(text.boxes[2], Rect.zero, reason: 'generated line break');
      expect(text.boxes[4], const Rect.fromLTRB(0, 20, 10, 30));
    });

    test('lines that the page text already covers are not added twice', () {
      const native = PdfPageText('hello', [
        Rect.fromLTWH(0, 0, 10, 10),
        Rect.fromLTWH(10, 0, 10, 10),
        Rect.fromLTWH(20, 0, 10, 10),
        Rect.fromLTWH(30, 0, 10, 10),
        Rect.fromLTWH(40, 0, 10, 10),
      ]);
      final merged = mergeOcr(native, const [
        PdfOcrLine('hello', Rect.fromLTRB(0, 0, 50, 10)),
        PdfOcrLine('in the picture', Rect.fromLTRB(0, 40, 140, 50)),
      ]);
      expect(merged.text, 'hello\r\nin the picture');
    });
  });

  group('PdfController OCR', () {
    Future<PdfController> open(TextRecognizer? recognizer) async {
      final controller = PdfController(textRecognizer: recognizer);
      addTearDown(controller.dispose);
      await controller.loadFile(_features);
      expect(controller.error, isNull);
      return controller;
    }

    test('without a recognizer there is no OCR', () async {
      final controller = await open(null);
      expect(controller.canRecognize, isFalse);
      expect(await controller.pageNeedsOcr(3), isFalse);
      expect(await controller.recognizePage(3), isFalse);
      expect(controller.ocrStatusOf(3), PdfOcrStatus.idle);
    });

    test('an unavailable recognizer is treated as none', () async {
      final recognizer = _FakeRecognizer(available: false);
      final controller = await open(recognizer);
      expect(controller.canRecognize, isFalse);
      expect(await controller.recognizePage(3), isFalse);
      expect(recognizer.inputs, isEmpty);
    });

    test('only a page with no text of its own needs OCR', () async {
      final controller = await open(_FakeRecognizer());
      expect(await controller.pageNeedsOcr(0), isFalse, reason: 'page 1 has text');
      expect(await controller.pageNeedsOcr(3), isTrue, reason: 'page 4 is a scan');
    });

    test('a scanned page, once recognised, selects and copies like text', () async {
      final recognizer = _FakeRecognizer(
        lines: const [
          OcrLine(text: 'Scanned words', rect: Rect.fromLTWH(100, 200, 700, 80)),
          OcrLine(text: 'second line', rect: Rect.fromLTWH(100, 300, 700, 80)),
        ],
      );
      final controller = await open(recognizer);
      expect(controller.ocrStatusOf(3), PdfOcrStatus.idle);

      final found = await controller.recognizePage(3, languageHints: const ['en']);
      expect(found, isTrue);
      expect(controller.ocrStatusOf(3), PdfOcrStatus.done);
      expect(await controller.pageNeedsOcr(3), isFalse, reason: 'already read');

      final input = recognizer.inputs.single;
      expect(input.languageHints, ['en']);
      expect(input.png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

      final layer = (await controller.selection.loadLayer(3))!;
      expect(layer.isEmpty, isFalse);
      expect(layer.text, 'Scanned words\r\nsecond line');
      controller.selection.select(const PdfCaret(3, 0), const PdfCaret(3, PdfCaret.end));
      expect(await controller.copySelection(), isTrue);
      expect(clipboard, 'Scanned words\nsecond line');
      expect(await controller.allText(), contains('Scanned words'));
    });

    test('the recognised box sits where the line is on the page', () async {
      final recognizer = _FakeRecognizer(
        lines: const [OcrLine(text: 'abcd', rect: Rect.fromLTWH(0, 0, 400, 100))],
      );
      final controller = await open(recognizer);
      await controller.recognizePage(3);
      final layer = (await controller.selection.loadLayer(3))!;
      final input = recognizer.inputs.single;
      final page = controller.document!.pageSizes[3];
      final expectedWidth = 400 * page.width / input.width;
      expect(layer.boxes[3].right, closeTo(expectedWidth, 0.01));
    });

    test('asking twice while it runs reads the page once', () async {
      final gate = Completer<void>();
      final recognizer = _FakeRecognizer(
        gate: gate,
        lines: const [OcrLine(text: 'x', rect: Rect.fromLTWH(0, 0, 10, 10))],
      );
      final controller = await open(recognizer);
      final first = controller.recognizePage(3);
      final second = controller.recognizePage(3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.ocrStatusOf(3), PdfOcrStatus.running);
      gate.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(recognizer.inputs, hasLength(1));
    });

    test('a failed read is reported and can be retried', () async {
      final controller = await open(_FakeRecognizer(fail: true));
      expect(await controller.recognizePage(3), isFalse);
      expect(controller.ocrStatusOf(3), PdfOcrStatus.failed);
      expect(controller.ocrErrorOf(3), isA<StateError>());
      expect(await controller.pageNeedsOcr(3), isTrue, reason: 'worth offering again');
    });

    test('a cancelled read leaves the page as it was', () async {
      final gate = Completer<void>();
      final recognizer = _FakeRecognizer(
        gate: gate,
        lines: const [OcrLine(text: 'x', rect: Rect.fromLTWH(0, 0, 10, 10))],
      );
      final controller = await open(recognizer);
      final run = controller.recognizePage(3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      controller.cancelOcr(3);
      gate.complete();
      expect(await run, isFalse);
      expect(controller.ocrStatusOf(3), PdfOcrStatus.idle);
      expect(controller.selection.hasOcr(3), isFalse);
    });

    test('a page with nothing readable is done with no text', () async {
      final controller = await open(_FakeRecognizer());
      expect(await controller.recognizePage(3), isFalse);
      expect(controller.ocrStatusOf(3), PdfOcrStatus.done);
      expect((await controller.selection.loadLayer(3))!.isEmpty, isTrue);
    });

    test('listeners hear about progress', () async {
      final controller = await open(
        _FakeRecognizer(
          lines: const [OcrLine(text: 'x', rect: Rect.fromLTWH(0, 0, 10, 10))],
        ),
      );
      var calls = 0;
      controller.addListener(() => calls++);
      await controller.recognizePage(3);
      expect(calls, greaterThanOrEqualTo(2), reason: 'running, then done');
    });
  });
}
