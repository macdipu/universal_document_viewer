import 'dart:convert';
import 'dart:typed_data';

/// UTF-8 first; Latin-1 (which accepts every byte) as the fallback for a
/// non-UTF-8 file. Not full charset auto-detection - shared by the Text and
/// CSV readers (`FEATURE-OPENREADER-P4/SRS.md` Unresolved Question 3's
/// deliberately narrow scope).
///
/// A byte order mark is the one hint taken: it is dropped (a UTF-8 BOM
/// would otherwise sit in the first line, or the first CSV header), and a
/// UTF-16 one - how Windows Notepad saves "Unicode" - decodes the rest as
/// UTF-16 in that byte order.
String decodeTextBytes(Uint8List bytes) {
  if (hasUtf16Bom(bytes)) return _utf16(bytes, littleEndian: bytes[0] == 0xFF);
  final body = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
      ? Uint8List.sublistView(bytes, 3)
      : bytes;
  try {
    return utf8.decode(body);
  } on FormatException {
    return latin1.decode(body);
  }
}

/// Whether [bytes] start with a UTF-16 byte order mark (`FF FE` or `FE FF`).
/// UTF-16 text is full of NUL bytes, so a binary-file check should ask this
/// first.
bool hasUtf16Bom(Uint8List bytes) =>
    bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF));

String _utf16(Uint8List bytes, {required bool littleEndian}) {
  final units = Uint16List((bytes.length - 2) ~/ 2);
  final data = ByteData.sublistView(bytes, 2);
  for (var i = 0; i < units.length; i++) {
    units[i] = data.getUint16(i * 2, littleEndian ? Endian.little : Endian.big);
  }
  return String.fromCharCodes(units);
}
