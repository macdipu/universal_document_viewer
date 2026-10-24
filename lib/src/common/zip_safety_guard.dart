import 'dart:typed_data';

import 'package:archive/archive.dart';

/// BRD §12.5 zip-bomb/path-traversal guard for DOCX/XLSX ZIP containers
/// (ODF-P5-03), run before handing bytes to the Word and spreadsheet engines.
///
/// `ZipDecoder.decodeBytes` only parses the central directory - confirmed by
/// reading `archive` 4.3.0's source, not assumed from its README - so
/// [check] never decompresses entry content and stays cheap even for a
/// maliciously crafted archive.
///
/// It vets the sizes the archive *declares*. That an entry can't inflate
/// past its declared size is enforced where it's read: by `archive` itself
/// since 4.5.0 (hence the `^4.5.0` constraint) and, independently, by the
/// kit's `OpcPackage`.
enum ZipSafetyResult {
  /// Safe to decompress and parse.
  safe,

  /// Structurally a ZIP, but its declared entry count or total uncompressed
  /// size exceeds the ceiling - reuses BRD §13's "too large" message.
  tooLarge,

  /// Not a well-formed ZIP, or an entry name attempts path traversal -
  /// reuses BRD §13's generic "damaged or incomplete" message. A real
  /// password-protected `.docx`/`.xlsx` also lands here: Office wraps the
  /// whole package in an OLE2 compound file, not a ZIP, so it fails to
  /// parse as one (ODF-P5-04).
  corrupted,
}

class ZipSafetyGuard {
  /// First-pass, adjustable ceilings, not BRD-specified numbers - same
  /// posture as `CsvReaderController.maxBytes`/`TextReaderController.maxBytes`.
  static const int maxEntryCount = 10000;
  static const int maxUncompressedBytes = 500 * 1024 * 1024;

  /// Largest Office file read at all. Readers check the file's length
  /// against it before reading it into memory - the guard can only look at
  /// bytes already read.
  static const int maxFileBytes = 200 * 1024 * 1024;

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

  static bool _isUnsafePath(String name) {
    if (name.startsWith('/') || name.startsWith(r'\')) return true;
    final normalized = name.replaceAll(r'\', '/');
    return normalized.split('/').contains('..');
  }
}
