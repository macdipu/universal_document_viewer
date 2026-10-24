import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/engines/pdfium/pdf_engine.dart';
import 'package:universal_document_viewer/src/engines/pdfium/pdf_types.dart';
import 'package:universal_document_viewer/src/engines/pdfium/pdfium_worker.dart';

const _features = 'test/fixtures/pdf/features.pdf';

/// The real worker loop, with PDFium failing to load (as with libpdfium
/// missing: the first call into it throws).
void _workerWithoutLibrary(SendPort replies) =>
    runPdfiumWorker(replies, () => throw ArgumentError('Couldn\'t resolve native function FPDF_InitLibrary'));

/// A worker that starts, then dies on its first request.
void _workerDyingOnRequest(SendPort replies) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((_) => throw StateError('worker crashed'));
}

/// A worker that dies before it sends its port.
void _workerDyingAtStart(SendPort replies) => throw StateError('worker crashed at start');

/// Fails the test instead of hanging it when a call never completes.
Future<T> _soon<T>(Future<T> future) => future.timeout(const Duration(seconds: 10));

void main() {
  tearDown(debugResetPdfWorker);

  test('PDFium failing to load fails every call at once', () async {
    debugResetPdfWorker(_workerWithoutLibrary);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        _soon(PdfiumDocument.openFile(_features)),
        throwsA(isA<PdfEngineException>().having((e) => e.message, 'message', contains('could not be loaded'))),
      );
    }
  });

  test('a worker dying fails the waiting call and every later one', () async {
    debugResetPdfWorker(_workerDyingOnRequest);
    await expectLater(_soon(PdfiumDocument.openFile(_features)), throwsA(isA<PdfEngineException>()));
    // Fails at once: the dead worker isn't asked again.
    await expectLater(_soon(PdfiumDocument.openFile(_features)), throwsA(isA<PdfEngineException>()));
  });

  test('a worker dying before it is ready fails the call', () async {
    debugResetPdfWorker(_workerDyingAtStart);
    await expectLater(
      _soon(PdfiumDocument.openFile(_features)),
      throwsA(isA<PdfEngineException>().having((e) => e.message, 'message', contains('stopped'))),
    );
  });

  test('the real worker works again after a reset', () async {
    final document = await _soon(PdfiumDocument.openFile(_features));
    expect(document.pageCount, 4);
    await document.close();
  });
}
