import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pdfium_bindings.g.dart';

/// The PDFium worker isolate: the only place PDFium is called (it isn't
/// thread-safe).
///
/// Requests arrive as `[id, op, priority, ...args]` and are queued by
/// priority (lower first), then arrival. Between two tasks the isolate goes
/// back to its event loop, so a request that arrives meanwhile - or a
/// cancel - is seen before the next task starts. Replies are
/// `[id, result]` or `[id, null, errorCode, message]`.
void pdfiumWorkerMain(SendPort replies) => runPdfiumWorker(replies, FPDF_InitLibrary);

/// The worker loop, with [init] standing for `FPDF_InitLibrary` (tests pass
/// one that fails).
///
/// The request port is sent before [init] runs, and a failing [init] (the
/// usual cause: libpdfium missing or unloadable, which throws on the first
/// call into it) doesn't end the isolate: every request is then answered
/// with an `engine` error, so callers fail at once instead of waiting on a
/// worker that will never reply.
void runPdfiumWorker(SendPort replies, void Function() init) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  String? initError;
  try {
    init();
  } catch (e) {
    initError = 'PDFium could not be loaded: $e';
  }
  final worker = _Worker(replies, initError);
  requests.listen((message) => worker.receive(message as List<Object?>));
}

/// Operation names shared with the main-isolate side.
abstract final class PdfiumOp {
  static const open = 'open';
  static const close = 'close';
  static const render = 'render';
  static const text = 'text';
  static const search = 'search';
  static const links = 'links';
  static const cancel = 'cancel';
}

class _Task {
  _Task(this.id, this.op, this.priority, this.args, this.order);

  final int id;
  final String op;
  final int priority;
  final List<Object?> args;
  final int order;
}

/// What mapping a page's PDF coordinates to the displayed page needs.
class _PageGeometry {
  _PageGeometry(this.rotation, this.left, this.top, this.right, this.bottom);

  /// Quarter turns clockwise (`/Rotate` / 90).
  final int rotation;

  /// The crop box in PDF coordinates (origin bottom-left).
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// PDF coordinates -> displayed page coordinates (origin top-left).
  (double, double) toDisplay(double x, double y) {
    final u = x - left;
    final v = top - y;
    final w0 = right - left;
    final h0 = top - bottom;
    return switch (rotation & 3) {
      1 => (h0 - v, u),
      2 => (w0 - u, h0 - v),
      3 => (v, w0 - u),
      _ => (u, v),
    };
  }

  /// A PDF-coordinate rectangle on the displayed page, as
  /// `[left, top, right, bottom]`.
  List<double> rectToDisplay(double l, double t, double r, double b) {
    final (x1, y1) = toDisplay(l, t);
    final (x2, y2) = toDisplay(r, b);
    return [math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)];
  }
}

class _Document {
  _Document(this.handle, this.pageCount, this.buffer);

  final Pointer<fpdf_document_t__> handle;
  final int pageCount;

  /// Pages' geometry, read on first use.
  final _geometry = <int, _PageGeometry>{};

  /// The bytes of a document opened from memory, which PDFium reads from
  /// until it's closed.
  final Pointer<Uint8>? buffer;

  /// Recently used page and text-page handles (most recent last), so
  /// rendering a page's tiles or searching it doesn't reload it each time.
  final _pageCache = LinkedHashMap<int, Pointer<fpdf_page_t__>>();
  final _textCache = LinkedHashMap<int, Pointer<fpdf_textpage_t__>>();
  static const _cacheSize = 6;

  Pointer<fpdf_page_t__> page(int index) {
    final cached = _pageCache.remove(index);
    if (cached != null) return _pageCache[index] = cached;
    final page = FPDF_LoadPage(handle, index);
    if (page == nullptr) throw const _WorkerError('page', 'Page could not be loaded');
    _pageCache[index] = page;
    while (_pageCache.length > _cacheSize) {
      final oldest = _pageCache.keys.first;
      _closeText(oldest);
      FPDF_ClosePage(_pageCache.remove(oldest)!);
    }
    return page;
  }

  /// The page's rotation and crop box, for mapping text and link boxes to
  /// the displayed page.
  _PageGeometry geometry(int index) => _geometry[index] ??= using((arena) {
        final page = this.page(index);
        final rotation = FPDFPage_GetRotation(page) & 3;
        final box = arena<FS_RECTF>();
        final double left, top, right, bottom;
        if (FPDF_GetPageBoundingBox(page, box) != 0) {
          (left, top, right, bottom) = (box.ref.left, box.ref.top, box.ref.right, box.ref.bottom);
        } else {
          (left, top, right, bottom) = (0, FPDF_GetPageHeightF(page), FPDF_GetPageWidthF(page), 0);
        }
        return _PageGeometry(rotation, left, top, right, bottom);
      });

  Pointer<fpdf_textpage_t__> textPage(int index) {
    final cached = _textCache.remove(index);
    if (cached != null) return _textCache[index] = cached;
    final text = FPDFText_LoadPage(page(index));
    if (text == nullptr) throw const _WorkerError('page', 'Page text could not be loaded');
    _textCache[index] = text;
    return text;
  }

  void _closeText(int index) {
    final text = _textCache.remove(index);
    if (text != null) FPDFText_ClosePage(text);
  }

  void close() {
    for (final text in _textCache.values) {
      FPDFText_ClosePage(text);
    }
    for (final page in _pageCache.values) {
      FPDF_ClosePage(page);
    }
    _textCache.clear();
    _pageCache.clear();
    FPDF_CloseDocument(handle);
    if (buffer != null) malloc.free(buffer!);
  }
}

class _WorkerError implements Exception {
  const _WorkerError(this.code, this.message);
  final String code;
  final String message;
}

class _Worker {
  _Worker(this._replies, this._initError);

  final SendPort _replies;

  /// Why PDFium isn't usable; while set, requests fail without touching it.
  final String? _initError;
  final _queue = <_Task>[];
  final _documents = <int, _Document>{};
  var _nextDocument = 1;
  var _order = 0;
  var _scheduled = false;

  void receive(List<Object?> message) {
    final id = message[0]! as int;
    final op = message[1]! as String;
    if (op == PdfiumOp.cancel) {
      final target = message[3]! as int;
      _queue.removeWhere((task) => task.id == target);
      return;
    }
    if (_initError case final error?) {
      _replies.send([id, null, 'engine', error]);
      return;
    }
    var priority = message[2]! as int;
    if (op == PdfiumOp.close) {
      // Closing frees the document now rather than after every queued
      // request for it (a thumbnail strip can queue many): those are
      // answered as closed, and the close runs before anything else.
      final document = message[3];
      _queue.removeWhere((task) {
        if (task.op == PdfiumOp.open || task.args.first != document) return false;
        _replies.send([task.id, null, 'closed', 'Document is closed']);
        return true;
      });
      priority = -1;
    }
    _queue.add(_Task(id, op, priority, message.sublist(3), _order++));
    _schedule();
  }

  void _schedule() {
    if (_scheduled || _queue.isEmpty) return;
    _scheduled = true;
    // Back to the event loop first, so newer and higher-priority requests
    // (and cancels) are in the queue before the next task is picked.
    Timer.run(_runNext);
  }

  void _runNext() {
    _scheduled = false;
    if (_queue.isEmpty) return;
    var best = 0;
    for (var i = 1; i < _queue.length; i++) {
      final a = _queue[i];
      final b = _queue[best];
      if (a.priority < b.priority || (a.priority == b.priority && a.order < b.order)) best = i;
    }
    final task = _queue.removeAt(best);
    try {
      _replies.send([task.id, _run(task)]);
    } on _WorkerError catch (e) {
      _replies.send([task.id, null, e.code, e.message]);
    } catch (e) {
      _replies.send([task.id, null, 'internal', '$e']);
    }
    _schedule();
  }

  _Document _document(Object? id) =>
      _documents[id] ?? (throw const _WorkerError('closed', 'Document is closed'));

  Object? _run(_Task task) {
    final args = task.args;
    return switch (task.op) {
      PdfiumOp.open => _open(args[0], args[1] as String?),
      PdfiumOp.close => _close(args[0]! as int),
      PdfiumOp.render => _render(
          _document(args[0]),
          args[1]! as int,
          fullWidth: args[2]! as int,
          fullHeight: args[3]! as int,
          x: args[4]! as int,
          y: args[5]! as int,
          width: args[6]! as int,
          height: args[7]! as int,
        ),
      PdfiumOp.text => _text(_document(args[0]), args[1]! as int),
      PdfiumOp.search => _search(_document(args[0]), args[1]! as int, args[2]! as String),
      PdfiumOp.links => _links(_document(args[0]), args[1]! as int),
      _ => throw _WorkerError('internal', 'Unknown operation ${task.op}'),
    };
  }

  /// Opens a document from a path (String) or bytes (TransferableTypedData).
  /// The last-error code is read here, in the same call as the load:
  /// PDFium keeps it per thread.
  Object? _open(Object? source, String? password) {
    return using((arena) {
      final passwordPtr = password == null ? nullptr : password.toNativeUtf8(allocator: arena).cast<Char>();
      Pointer<fpdf_document_t__> handle;
      Pointer<Uint8>? buffer;
      if (source is String) {
        handle = FPDF_LoadDocument(source.toNativeUtf8(allocator: arena).cast(), passwordPtr);
      } else {
        final bytes = (source! as TransferableTypedData).materialize().asUint8List();
        // PDFium reads from this buffer for the document's whole life.
        buffer = malloc<Uint8>(bytes.length);
        buffer.asTypedList(bytes.length).setAll(0, bytes);
        handle = FPDF_LoadMemDocument64(buffer.cast(), bytes.length, passwordPtr);
      }
      if (handle == nullptr) {
        final error = FPDF_GetLastError();
        if (buffer != null) malloc.free(buffer);
        throw _WorkerError('open', '$error');
      }
      // Sizes without loading any page (it applies /Rotate), so a long
      // document opens at once; each page's full geometry is read when
      // first needed (see [_Document.geometry]).
      final count = FPDF_GetPageCount(handle);
      final sizes = Float64List(count * 2);
      final size = arena<FS_SIZEF>();
      for (var i = 0; i < count; i++) {
        final ok = FPDF_GetPageSizeByIndexF(handle, i, size) != 0;
        sizes[i * 2] = ok ? size.ref.width : 612;
        sizes[i * 2 + 1] = ok ? size.ref.height : 792;
      }
      final id = _nextDocument++;
      _documents[id] = _Document(handle, count, buffer);
      return [id, sizes];
    });
  }

  Object? _close(int id) {
    _documents.remove(id)?.close();
    return null;
  }

  /// Renders part of a page: the page drawn at [fullWidth] x [fullHeight]
  /// pixels, of which the [width] x [height] region at ([x], [y]) is
  /// returned as RGBA bytes on white.
  Object? _render(
    _Document document,
    int index, {
    required int fullWidth,
    required int fullHeight,
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) throw const _WorkerError('render', 'Empty region');
    final page = document.page(index);
    final stride = width * 4;
    final buffer = malloc<Uint8>(stride * height);
    try {
      final bitmap = FPDFBitmap_CreateEx(width, height, FPDFBitmap_BGRA, buffer.cast(), stride);
      if (bitmap == nullptr) throw const _WorkerError('render', 'Bitmap could not be created');
      try {
        FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
        // Rotation 0: PDFium applies the page's own /Rotate. Byte order
        // reversed: RGBA, which Flutter decodes everywhere.
        FPDF_RenderPageBitmap(bitmap, page, -x, -y, fullWidth, fullHeight, 0, FPDF_ANNOT | FPDF_REVERSE_BYTE_ORDER);
      } finally {
        FPDFBitmap_Destroy(bitmap);
      }
      return TransferableTypedData.fromList([buffer.asTypedList(stride * height)]);
    } finally {
      malloc.free(buffer);
    }
  }

  /// The page's text and character boxes (`[l, t, r, b]` per character,
  /// display coordinates).
  Object? _text(_Document document, int index) {
    final (text, boxes) = _readText(document, index);
    return [text, boxes];
  }

  (String, Float32List) _readText(_Document document, int index) {
    final textPage = document.textPage(index);
    final geometry = document.geometry(index);
    final count = math.max(0, FPDFText_CountChars(textPage));
    final units = Uint16List(count);
    final boxes = Float32List(count * 4);
    using((arena) {
      final l = arena<Double>();
      final r = arena<Double>();
      final b = arena<Double>();
      final t = arena<Double>();
      for (var i = 0; i < count; i++) {
        final code = FPDFText_GetUnicode(textPage, i);
        units[i] = code > 0xFFFF ? 0xFFFD : code;
        if (FPDFText_GetCharBox(textPage, i, l, r, b, t) != 0) {
          final rect = geometry.rectToDisplay(l.value, t.value, r.value, b.value);
          boxes.setRange(i * 4, i * 4 + 4, rect);
        }
      }
    });
    return (String.fromCharCodes(units), boxes);
  }

  /// Every match of [query] on a page, ignoring case and line breaks:
  /// `[start, end, rects...]` per match, rects as `[l, t, r, b]` merged per
  /// line.
  Object? _search(_Document document, int index, String query) {
    final (text, boxes) = _readText(document, index);
    final needle = _fold(query.replaceAll(RegExp(r'\s+'), ' ').trim());
    if (needle.isEmpty || text.isEmpty) return [text.isNotEmpty, <Object>[]];
    // Line breaks (PDFium's generated "\r\n") read as one space, so a
    // phrase that wraps still matches; [offsets] maps back to the text.
    final normalized = StringBuffer();
    final offsets = <int>[];
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x0A && i > 0 && text.codeUnitAt(i - 1) == 0x0D) continue;
      normalized.writeCharCode(unit == 0x0D || unit == 0x0A ? 0x20 : unit);
      offsets.add(i);
    }
    offsets.add(text.length);
    final haystack = _fold(normalized.toString());
    final matches = <Object>[];
    var at = haystack.indexOf(needle);
    while (at != -1) {
      final start = offsets[at];
      final end = offsets[at + needle.length];
      matches.add([start, end, _lineRects(boxes, start, end, sideways: document.geometry(index).rotation.isOdd)]);
      at = haystack.indexOf(needle, at + needle.length);
    }
    return [true, matches];
  }

  /// The boxes of characters [start]-[end], merged into one rect per line.
  /// On a page turned [sideways] (90 or 270 degrees) lines run up or down
  /// the screen, so boxes on one line overlap horizontally, not vertically.
  static Float32List _lineRects(Float32List boxes, int start, int end, {required bool sideways}) {
    final rects = <double>[];
    for (var i = start; i < end; i++) {
      final l = boxes[i * 4], t = boxes[i * 4 + 1], r = boxes[i * 4 + 2], b = boxes[i * 4 + 3];
      if (r <= l && b <= t) continue;
      final last = rects.length - 4;
      final sameLine = last >= 0 &&
          (sideways ? l < rects[last + 2] && r > rects[last] : t < rects[last + 3] && b > rects[last + 1]);
      if (sameLine) {
        rects[last] = math.min(rects[last], l);
        rects[last + 1] = math.min(rects[last + 1], t);
        rects[last + 2] = math.max(rects[last + 2], r);
        rects[last + 3] = math.max(rects[last + 3], b);
      } else {
        rects.addAll([l, t, r, b]);
      }
    }
    return Float32List.fromList(rects);
  }

  /// Link annotations, plus web addresses written as text: `[url or null,
  /// page or -1, rects...]` per link.
  Object? _links(_Document document, int index) {
    final page = document.page(index);
    final geometry = document.geometry(index);
    final links = <Object>[];
    using((arena) {
      final position = arena<Int>()..value = 0;
      final link = arena<Pointer<fpdf_link_t__>>();
      final rect = arena<FS_RECTF>();
      while (FPDFLink_Enumerate(page, position, link) != 0) {
        if (FPDFLink_GetAnnotRect(link.value, rect) == 0) continue;
        String? url;
        var target = -1;
        final action = FPDFLink_GetAction(link.value);
        var destination = FPDFLink_GetDest(document.handle, link.value);
        if (action != nullptr) {
          switch (FPDFAction_GetType(action)) {
            case PDFACTION_URI:
              final length = FPDFAction_GetURIPath(document.handle, action, nullptr, 0);
              if (length > 1) {
                final buffer = arena<Uint8>(length);
                FPDFAction_GetURIPath(document.handle, action, buffer.cast(), length);
                url = String.fromCharCodes(buffer.asTypedList(length - 1));
              }
            case PDFACTION_GOTO:
              destination = FPDFAction_GetDest(document.handle, action);
          }
        }
        if (destination != nullptr) target = FPDFDest_GetDestPageIndex(document.handle, destination);
        if (url == null && target < 0) continue;
        final r = rect.ref;
        links.add([url, target, Float32List.fromList(geometry.rectToDisplay(r.left, r.top, r.right, r.bottom))]);
      }
      final webLinks = FPDFLink_LoadWebLinks(document.textPage(index));
      if (webLinks != nullptr) {
        try {
          final left = arena<Double>(), top = arena<Double>(), right = arena<Double>(), bottom = arena<Double>();
          for (var i = 0; i < FPDFLink_CountWebLinks(webLinks); i++) {
            final length = FPDFLink_GetURL(webLinks, i, nullptr, 0);
            if (length <= 1) continue;
            final buffer = arena<UnsignedShort>(length);
            FPDFLink_GetURL(webLinks, i, buffer, length);
            final url = String.fromCharCodes(buffer.cast<Uint16>().asTypedList(length - 1));
            final rects = <double>[];
            for (var j = 0; j < FPDFLink_CountRects(webLinks, i); j++) {
              if (FPDFLink_GetRect(webLinks, i, j, left, top, right, bottom) != 0) {
                rects.addAll(geometry.rectToDisplay(left.value, top.value, right.value, bottom.value));
              }
            }
            if (rects.isNotEmpty) links.add([url, -1, Float32List.fromList(rects)]);
          }
        } finally {
          FPDFLink_CloseWebLinks(webLinks);
        }
      }
    });
    return links;
  }

  /// Lower case one UTF-16 unit at a time, so offsets stay put.
  static String _fold(String text) {
    final lower = text.toLowerCase();
    if (lower.length == text.length) return lower;
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      final folded = String.fromCharCode(unit).toLowerCase();
      out.write(folded.length == 1 ? folded : String.fromCharCode(unit));
    }
    return out.toString();
  }
}
