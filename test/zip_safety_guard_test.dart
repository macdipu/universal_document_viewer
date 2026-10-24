import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

// Builds real ZIP archives via `archive`'s own encoder rather than hand-rolled
// byte layouts, so these tests exercise the exact central-directory shape
// ZipSafetyGuard.check reads.
Uint8List _zipWith(List<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('ZipSafetyGuard.check (ODF-P5-03)', () {
    test('accepts a small, well-formed archive', () {
      final bytes = _zipWith([ArchiveFile.string('word/document.xml', '<xml/>')]);
      expect(ZipSafetyGuard.check(bytes), ZipSafetyResult.safe);
    });

    test('rejects an entry count above the ceiling', () {
      final files = List.generate(
        ZipSafetyGuard.maxEntryCount + 1,
        (i) => ArchiveFile.string('f$i.xml', 'x'),
      );
      final bytes = _zipWith(files);
      expect(ZipSafetyGuard.check(bytes), ZipSafetyResult.tooLarge);
    });

    test('rejects total uncompressed size above the ceiling (zip-bomb shape)', () {
      // A single highly-compressible entry whose *declared* uncompressed
      // size alone exceeds the ceiling - the central directory carries this
      // size without OpenReader ever inflating the entry, which is the
      // whole point of checking it here rather than after decompression.
      final oversized = ArchiveFile(
        'huge.bin',
        ZipSafetyGuard.maxUncompressedBytes + 1,
        Uint8List(0),
      );
      final archive = Archive()..addFile(oversized);
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      expect(ZipSafetyGuard.check(bytes), ZipSafetyResult.tooLarge);
    });

    test('rejects a path-traversal entry name', () {
      final bytes = _zipWith([ArchiveFile.string('../../etc/passwd', 'pwned')]);
      expect(ZipSafetyGuard.check(bytes), ZipSafetyResult.corrupted);
    });

    test('rejects an absolute entry path', () {
      final bytes = _zipWith([ArchiveFile.string('/etc/passwd', 'pwned')]);
      expect(ZipSafetyGuard.check(bytes), ZipSafetyResult.corrupted);
    });

    test('rejects bytes that are not a ZIP at all', () {
      expect(ZipSafetyGuard.check(Uint8List.fromList([1, 2, 3, 4])), ZipSafetyResult.corrupted);
    });

    test('rejects an OLE2 compound-file signature (ODF-P5-04: what a real password-protected .docx/.xlsx looks like)', () {
      // Office wraps an encrypted OOXML package in an OLE2 compound file
      // (`EncryptedPackage`/`EncryptionInfo` streams), not a ZIP - it starts
      // with this exact 8-byte signature. No real encryption is needed to
      // verify the *fallback path*: the file is provably not ZIP-shaped,
      // which is the actual, structural reason it must not parse as one.
      final ole2Signature = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, ...List.filled(504, 0)]);
      expect(ZipSafetyGuard.check(ole2Signature), ZipSafetyResult.corrupted);
    });
  });
}
