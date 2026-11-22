import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/pdf.dart';
import 'package:universal_document_viewer/src/pdf/pdf_selection.dart';

const _features = 'test/fixtures/pdf/features.pdf';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfController controller;
  String? clipboard;

  setUp(() async {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
    controller = PdfController();
    await controller.loadFile(_features);
    expect(controller.error, isNull);
  });

  tearDown(() {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  test('nothing is selected at first', () {
    expect(controller.hasSelection.value, isFalse);
    expect(controller.selectedText(), isNull);
  });

  test('a range on one page gives its text, the rectangles to paint, and copies it', () async {
    final layer = (await controller.selection.loadLayer(0))!;
    final from = layer.text.indexOf('Quarterly');
    controller.selection.select(PdfCaret(0, from), PdfCaret(0, from + 'Quarterly Report'.length));
    expect(controller.hasSelection.value, isTrue);
    expect(controller.selectedText(), 'Quarterly Report');
    final rects = controller.selection.rectsOn(0);
    expect(rects, hasLength(1));
    expect(rects.single.left, closeTo(72, 2));
    expect(controller.selection.rectsOn(1), isEmpty);
    expect(await controller.copySelection(), isTrue);
    expect(clipboard, 'Quarterly Report');
  });

  test('the focus may come before the anchor', () async {
    final layer = (await controller.selection.loadLayer(0))!;
    final from = layer.text.indexOf('Quarterly');
    controller.selection.select(PdfCaret(0, from + 9), PdfCaret(0, from));
    expect(controller.selectedText(), 'Quarterly');
  });

  test('a range over pages reads the pages in between, joined by a blank line', () async {
    controller.selection.select(const PdfCaret(0, 0), const PdfCaret(2, PdfCaret.end));
    expect(await controller.copySelection(), isTrue);
    final page0 = (await controller.selection.loadLayer(0))!.text.replaceAll('\r\n', '\n').trim();
    expect(clipboard, startsWith(page0.split('\n').first));
    expect(clipboard, contains('\n\n'));
    // The rotated page's text reads like any other.
    expect(clipboard!.toLowerCase(), contains('needle'));
  });

  test('select all covers the whole document, a scanned page adds nothing', () async {
    controller.selectAll();
    expect(controller.hasSelection.value, isTrue);
    expect(await controller.copySelection(), isTrue);
    final all = await controller.allText();
    expect(clipboard, all);
    expect(all, contains('Quarterly Report alpha'));
    expect(controller.selection.rangeOn(3), isNull, reason: 'page 4 is a scan with no text');
  });

  test('clearSelection empties it, and so does opening another document', () async {
    controller.selectAll();
    controller.clearSelection();
    expect(controller.hasSelection.value, isFalse);
    expect(controller.selectedText(), isNull);
    expect(await controller.copySelection(), isFalse);
    controller.selectAll();
    await controller.loadFile('test/fixtures/pdf/encrypted.pdf').catchError((Object _) {});
    expect(controller.selection.hasSelection, isFalse);
  });

  test('layers are read once and kept to a bounded number', () async {
    final first = controller.selection.loadLayer(0);
    final second = controller.selection.loadLayer(0);
    expect(identical(await first, await second), isTrue);
    expect(controller.selection.layerOf(0), isNotNull);
    expect(controller.selection.layerOf(99), isNull);
    expect(await controller.selection.loadLayer(99), isNull);
  });

  test('a point on the page maps to a character of its text', () async {
    final layer = (await controller.selection.loadLayer(0))!;
    final q = layer.text.indexOf('Quarterly');
    final box = layer.boxes[q];
    expect(layer.charAt(box.center), q);
    expect(layer.wordAt(q), (q, q + 'Quarterly'.length));
    expect(layer.caretAt(Offset(box.left + 1, box.center.dy)), q);
  });

  test('the carets compare in reading order', () {
    expect(const PdfCaret(1, 0).compareTo(const PdfCaret(0, 99)), greaterThan(0));
    expect(const PdfCaret(1, 3).compareTo(const PdfCaret(1, 3)), 0);
    expect(const PdfCaret(1, 3), const PdfCaret(1, 3));
  });
}
