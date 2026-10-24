import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../common/zip_safety_guard.dart';

/// Reads the Office (ZIP) file at [path] and [parse]s it in a background
/// isolate, after [ZipSafetyGuard] - so only [parse]'s result crosses back
/// to the UI isolate. Null when the file is over
/// [ZipSafetyGuard.maxFileBytes] (checked before it's read) or the guard
/// refuses it. [parse] should keep only what the first page needs.
Future<T?> parseOfficeFile<T>(String path, T Function(Uint8List bytes) parse) async {
  if (await File(path).length() > ZipSafetyGuard.maxFileBytes) return null;
  return Isolate.run(() {
    final bytes = File(path).readAsBytesSync();
    if (ZipSafetyGuard.check(bytes) != ZipSafetyResult.safe) return null;
    return parse(bytes);
  });
}

/// The first [headBytes] of the text file at [path], cut after its last
/// whole line - or, in a head with no line break, before a UTF-8 character
/// the cut would split (a split one fails UTF-8 decoding and the whole head
/// falls back to Latin-1) - null for a file over [maxBytes], which its
/// reader would refuse too.
Future<Uint8List?> readTextHead(String path, {required int maxBytes, int headBytes = 32 * 1024}) async {
  final file = File(path);
  final length = await file.length();
  if (length > maxBytes) return null;
  final handle = await file.open();
  try {
    final head = await handle.read(math.min(length, headBytes));
    if (length <= headBytes) return head;
    final lastLineEnd = head.lastIndexOf(0x0A);
    if (lastLineEnd > 0) return Uint8List.sublistView(head, 0, lastLineEnd);
    return Uint8List.sublistView(head, 0, utf8Boundary(head));
  } finally {
    await handle.close();
  }
}

/// The length of [bytes] without a trailing, incomplete UTF-8 sequence:
/// [bytes].length when they end on a character boundary (or aren't UTF-8,
/// whose decoding doesn't care). Looks back at most three bytes, the
/// longest a sequence's tail can be.
int utf8Boundary(Uint8List bytes) {
  for (var back = 1; back <= 3 && back <= bytes.length; back++) {
    final byte = bytes[bytes.length - back];
    if (byte & 0xC0 == 0x80) continue; // A continuation byte: keep looking for the lead.
    // An ASCII byte ends a character; a lead byte's sequence is whole only
    // when it has all its continuation bytes after it.
    final needed = byte < 0x80 ? 1 : (byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2));
    return needed > back ? bytes.length - back : bytes.length;
  }
  return bytes.length;
}

/// Reads the whole text file at [path] and [parse]s it in a background
/// isolate - for a page past the head [readTextHead] reads - so only
/// [parse]'s result crosses back. Null for a file over [maxBytes].
Future<T?> parseTextFile<T>(String path, {required int maxBytes, required T Function(Uint8List bytes) parse}) async {
  if (await File(path).length() > maxBytes) return null;
  return Isolate.run(() => parse(File(path).readAsBytesSync()));
}
