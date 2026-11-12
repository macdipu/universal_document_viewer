import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'reader_contract.dart';

/// What [ZipSafetyGuard.check] found.
enum ZipSafetyResult {
  /// Safe to decompress and parse.
  safe,

  /// Structurally a ZIP, but its declared entry count or total uncompressed
  /// size exceeds the ceiling: [DocumentLoadError.tooLarge].
  tooLarge,

  /// Not a well-formed ZIP, or an entry name attempts path traversal:
  /// [DocumentLoadError.corrupted]. A password-protected `.docx`/`.xlsx`
  /// also lands here: Office wraps the whole package in an OLE2 compound
  /// file, not a ZIP, so it fails to parse as one. Tell that case apart
  /// with [ZipSafetyGuard.isEncryptedOfficeFile].
  corrupted,
}

/// Guards against zip bombs and path traversal in Office (OOXML) files:
/// run before handing bytes to the Word, spreadsheet and slide engines.
///
/// [check] reads only the ZIP's central directory (`archive`'s
/// `ZipDecoder.decodeBytes` doesn't decompress entries), so it stays cheap
/// even for a maliciously crafted archive. It vets the sizes the archive
/// *declares*. That an entry can't inflate past its declared size is
/// enforced where it's read: by `archive` itself since 4.5.0 (hence the
/// `^4.5.0` constraint) and, independently, by the package's ZIP reader.
///
/// The ceilings are conservative defaults, not standards.
class ZipSafetyGuard {
  /// The most entries an archive may declare.
  static const int maxEntryCount = 10000;

  /// The most bytes all entries together may declare uncompressed (500 MiB).
  static const int maxUncompressedBytes = 500 * 1024 * 1024;

  /// Largest Office file read at all. Readers check the file's length
  /// against it before reading it into memory - the guard can only look at
  /// bytes already read.
  static const int maxFileBytes = 200 * 1024 * 1024;

  /// Classifies [bytes] from the ZIP's central directory only, without
  /// decompressing any entry.
  static ZipSafetyResult check(Uint8List bytes) {
    if (bytes.length > maxFileBytes) return ZipSafetyResult.tooLarge;
    final decoder = ZipDecoder();
    final Archive archive;
    try {
      archive = decoder.decodeBytes(bytes);
    } catch (_) {
      return ZipSafetyResult.corrupted;
    }

    // `ZipDirectory.read` doesn't throw when it can't find an End Of Central
    // Directory record - it just leaves `filePosition` at -1 and returns
    // silently, which `decodeBytes` then surfaces as an empty `Archive`
    // (confirmed by reading `archive` 4.3.0's source). Without this check,
    // non-ZIP bytes (garbage, or a real password-protected .docx/.xlsx,
    // which Office wraps in an OLE2 compound file) would be misclassified as
    // a "safe" empty archive instead of rejected here.
    if (decoder.directory.filePosition < 0) return ZipSafetyResult.corrupted;

    if (archive.length > maxEntryCount) return ZipSafetyResult.tooLarge;

    var totalUncompressed = 0;
    for (final entry in archive) {
      if (_isUnsafePath(entry.name)) return ZipSafetyResult.corrupted;
      totalUncompressed += entry.size;
      if (totalUncompressed > maxUncompressedBytes) return ZipSafetyResult.tooLarge;
    }
    return ZipSafetyResult.safe;
  }

  /// Whether [bytes] are a password-protected Office file: an OLE2
  /// compound file (what Office writes instead of a ZIP when a document
  /// is encrypted) holding an `EncryptedPackage` stream (MS-OFFCRYPTO
  /// §2.3.4.4). A legacy binary `.xls`/`.doc` is OLE2 too but has no such
  /// stream, so it is not mistaken for an encrypted one. Meant for bytes
  /// [check] already called [ZipSafetyResult.corrupted]: it scans them.
  static bool isEncryptedOfficeFile(Uint8List bytes) {
    const ole2 = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    if (bytes.length < 512) return false;
    for (var i = 0; i < ole2.length; i++) {
      if (bytes[i] != ole2[i]) return false;
    }
    // Directory entry names are UTF-16LE.
    final name = [
      for (final unit in 'EncryptedPackage'.codeUnits) ...[unit, 0],
    ];
    final last = bytes.length - name.length;
    outer:
    for (var i = 512; i <= last; i++) {
      if (bytes[i] != name[0]) continue;
      for (var j = 1; j < name.length; j++) {
        if (bytes[i + j] != name[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  static bool _isUnsafePath(String name) {
    if (name.startsWith('/') || name.startsWith(r'\')) return true;
    final normalized = name.replaceAll(r'\', '/');
    return normalized.split('/').contains('..');
  }
}
