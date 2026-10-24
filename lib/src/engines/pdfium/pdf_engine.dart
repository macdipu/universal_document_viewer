import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'pdf_types.dart';
import 'pdfium_worker.dart';

/// The connection to the PDFium worker isolate, started on first use and
/// shared by every open document.
class _Worker {
  _Worker._(this._entryPoint);

  static _Worker? _instance;
  static _Worker get instance => _instance ??= _Worker._(pdfiumWorkerMain);

  final void Function(SendPort) _entryPoint;
  Future<SendPort>? _port;
  final _replies = ReceivePort();
  final _exits = RawReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 1;

  /// Set once the isolate has died (or never started). Nothing will answer
  /// after that, so every waiting and later call fails with it at once
  /// rather than waiting forever.
  PdfEngineException? _stopped;

  Future<SendPort> _start() => _port ??= () async {
        _replies.listen((message) {
          if (message is SendPort) {
            if (!_ready.isCompleted) _ready.complete(message);
            return;
          }
          final reply = message as List<Object?>;
          final completer = _pending.remove(reply[0]! as int);
          if (completer == null) return;
          if (reply.length > 2) {
            completer.completeError(_error(reply[2]! as String, reply[3]! as String));
          } else {
            completer.complete(reply[1]);
          }
        });
        // Error and exit ports are given to spawn itself, so a death even
        // before the isolate sends its port (or before a listener could be
        // attached) is still seen. An error message is `[error, stack]`;
        // the exit message is null.
        _exits.handler = (Object? message) =>
            _stop(message is List ? 'PDF engine stopped: ${message.first}' : 'PDF engine stopped');
        try {
          await Isolate.spawn(
            _entryPoint,
            _replies.sendPort,
            debugName: 'pdfium',
            onError: _exits.sendPort,
            onExit: _exits.sendPort,
          );
        } catch (e) {
          _stop('PDF engine could not start: $e');
        }
        return _ready.future;
      }();

  void _stop(String reason) {
    if (_stopped != null) return;
    final stopped = _stopped = PdfEngineException(reason);
    if (!_ready.isCompleted) _ready.completeError(stopped);
    final pending = [..._pending.values];
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(stopped);
    }
    _replies.close();
    _exits.close();
  }

  static Exception _error(String code, String message) => switch (code) {
        'open' => PdfOpenException(switch (int.tryParse(message)) {
            2 => PdfOpenError.file,
            3 => PdfOpenError.format,
            4 => PdfOpenError.password,
            5 => PdfOpenError.security,
            _ => PdfOpenError.unknown,
          }),
        'engine' => PdfEngineException(message),
        _ => PdfEngineException('$code: $message'),
      };

  /// Sends a request; [onId] receives its id (for [cancel]).
  Future<Object?> call(String op, List<Object?> args, {PdfPriority priority = PdfPriority.visible, void Function(int)? onId}) async {
    if (_stopped case final stopped?) throw stopped;
    final port = await _start();
    // It may have died while starting, after this request was made.
    if (_stopped case final stopped?) throw stopped;
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send([id, op, priority.index, ...args]);
    onId?.call(id);
    return completer.future;
  }

  /// Drops a request that hasn't started; its future fails with
  /// [PdfCancelledException]. (One already running still finishes; its
  /// result is discarded.)
  Future<void> cancel(int id) async {
    final completer = _pending.remove(id);
    if (completer == null) return;
    completer.completeError(const PdfCancelledException());
    // A stopped worker has nothing queued to drop.
    if (_stopped != null) return;
    try {
      (await _start()).send([0, PdfiumOp.cancel, 0, id]);
    } on PdfEngineException {
      // Stopped meanwhile: likewise.
    }
  }
}

/// Test hook: makes later PDF calls use a fresh worker started from
/// [entryPoint] (e.g. [runPdfiumWorker] with a failing init, or one that
/// dies), or the real one when null. The previous worker is left running.
@visibleForTesting
void debugResetPdfWorker([void Function(SendPort replies)? entryPoint]) {
  _Worker._instance = entryPoint == null ? null : _Worker._(entryPoint);
}

/// A rendered region of a page, as RGBA pixels.
class PdfRenderedImage {
  const PdfRenderedImage(this.pixels, this.width, this.height);

  final Uint8List pixels;
  final int width;
  final int height;

  /// Decodes into a [ui.Image] for painting.
  Future<ui.Image> toImage() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    try {
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}

/// A cancellable render request. [cancel] drops it if it hasn't started,
/// and [result] then fails with [PdfCancelledException].
class PdfRenderTask {
  /// A task that is cancelled (or fails) with nobody waiting on [result]
  /// mustn't surface as an uncaught error: render-and-forget and
  /// cancel-without-awaiting are both normal uses. Anyone awaiting
  /// [result] still gets its error.
  PdfRenderTask._(this.result) {
    result.ignore();
  }

  final Future<PdfRenderedImage> result;
  int? _id;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (_id != null) _Worker.instance.cancel(_id!);
  }

  /// The worker's id for the request; a cancel that came first is sent now.
  void _assign(int id) {
    _id = id;
    if (_cancelled) _Worker.instance.cancel(id);
  }
}

/// An open PDF. All PDFium work happens in one shared background isolate;
/// this object holds the document's id there and its page sizes.
class PdfiumDocument {
  PdfiumDocument._(this._id, this.pageSizes);

  final int _id;

  /// Each page's displayed size in points (rotation applied).
  final List<ui.Size> pageSizes;

  int get pageCount => pageSizes.length;

  bool _closed = false;
  bool get isClosed => _closed;

  /// Opens a PDF file. Throws [PdfOpenException] with
  /// [PdfOpenError.password] when it needs a (different) [password].
  static Future<PdfiumDocument> openFile(String path, {String? password}) =>
      _open(path, password);

  /// Opens a PDF held in memory.
  static Future<PdfiumDocument> openBytes(Uint8List bytes, {String? password}) =>
      _open(TransferableTypedData.fromList([bytes]), password);

  static Future<PdfiumDocument> _open(Object source, String? password) async {
    final reply = await _Worker.instance.call(PdfiumOp.open, [source, password]) as List<Object?>;
    final sizes = reply[1]! as Float64List;
    return PdfiumDocument._(reply[0]! as int, [
      for (var i = 0; i + 1 < sizes.length; i += 2) ui.Size(sizes[i], sizes[i + 1]),
    ]);
  }

  /// Renders page [page] (0-based) drawn at [fullWidth] x [fullHeight]
  /// pixels, returning the region [region] of it (all of it by default).
  PdfRenderTask render(
    int page, {
    required int fullWidth,
    required int fullHeight,
    ui.Rect? region,
    PdfPriority priority = PdfPriority.visible,
  }) {
    final area = region ?? ui.Rect.fromLTWH(0, 0, fullWidth.toDouble(), fullHeight.toDouble());
    final x = area.left.floor();
    final y = area.top.floor();
    final width = area.right.ceil() - x;
    final height = area.bottom.ceil() - y;
    late final PdfRenderTask task;
    task = PdfRenderTask._(() async {
      _checkOpen();
      final bytes = await _Worker.instance.call(
        PdfiumOp.render,
        [_id, page, fullWidth, fullHeight, x, y, width, height],
        priority: priority,
        onId: (id) => task._assign(id),
      ) as TransferableTypedData;
      return PdfRenderedImage(bytes.materialize().asUint8List(), width, height);
    }());
    return task;
  }

  /// A whole page scaled down to [width] pixels wide.
  Future<PdfRenderedImage> renderThumbnail(
    int page, {
    required int width,
    PdfPriority priority = PdfPriority.background,
  }) =>
      renderThumbnailTask(page, width: width, priority: priority).result;

  /// [renderThumbnail] as a cancellable task, for a thumbnail that may
  /// scroll away (or whose document may close) before it's drawn. A page
  /// out of range fails the task with [PdfEngineException], like any other
  /// render error, rather than throwing here.
  PdfRenderTask renderThumbnailTask(int page, {required int width, PdfPriority priority = PdfPriority.background}) {
    if (page < 0 || page >= pageCount) {
      return PdfRenderTask._(Future.error(PdfEngineException('page: Page ${page + 1} is out of range (1-$pageCount)')));
    }
    final size = pageSizes[page];
    final height = (width * size.height / size.width).round().clamp(1, 1 << 14);
    return render(page, fullWidth: width, fullHeight: height, priority: priority);
  }

  /// The page's text with each character's box.
  Future<PdfPageText> text(int page, {PdfPriority priority = PdfPriority.prefetch}) async {
    _checkOpen();
    final reply = await _Worker.instance.call(PdfiumOp.text, [_id, page], priority: priority) as List<Object?>;
    final text = reply[0]! as String;
    final boxes = reply[1]! as Float32List;
    return PdfPageText(text, [
      for (var i = 0; i + 3 < boxes.length; i += 4) ui.Rect.fromLTRB(boxes[i], boxes[i + 1], boxes[i + 2], boxes[i + 3]),
    ]);
  }

  /// Matches of [query] on one page (case-insensitive; a phrase may wrap
  /// lines), and whether the page has any text at all.
  Future<(bool hasText, List<PdfTextMatch>)> search(int page, String query, {PdfPriority priority = PdfPriority.prefetch}) async {
    _checkOpen();
    final reply = await _Worker.instance.call(PdfiumOp.search, [_id, page, query], priority: priority) as List<Object?>;
    final matches = <PdfTextMatch>[];
    for (final entry in reply[1]! as List<Object?>) {
      final match = entry! as List<Object?>;
      final rects = match[2]! as Float32List;
      matches.add(PdfTextMatch(
        page: page,
        start: match[0]! as int,
        end: match[1]! as int,
        rects: [
          for (var i = 0; i + 3 < rects.length; i += 4) ui.Rect.fromLTRB(rects[i], rects[i + 1], rects[i + 2], rects[i + 3]),
        ],
      ));
    }
    return (reply[0]! as bool, matches);
  }

  /// Links on a page: annotations and web addresses written as text.
  Future<List<PdfLink>> links(int page, {PdfPriority priority = PdfPriority.prefetch}) async {
    _checkOpen();
    final reply = await _Worker.instance.call(PdfiumOp.links, [_id, page], priority: priority) as List<Object?>;
    return [
      for (final entry in reply)
        () {
          final link = entry! as List<Object?>;
          final rects = link[2]! as Float32List;
          final target = link[1]! as int;
          return PdfLink(
            url: link[0] as String?,
            page: target >= 0 ? target : null,
            rects: [
              for (var i = 0; i + 3 < rects.length; i += 4)
                ui.Rect.fromLTRB(rects[i], rects[i + 1], rects[i + 2], rects[i + 3]),
            ],
          );
        }(),
    ];
  }

  /// Frees the document. The worker runs this ahead of anything queued and
  /// drops the document's queued requests (their futures fail), so closing
  /// isn't held up behind a strip of thumbnails.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _Worker.instance.call(PdfiumOp.close, [_id]);
  }

  void _checkOpen() {
    if (_closed) throw const PdfEngineException('Document is closed');
  }
}
