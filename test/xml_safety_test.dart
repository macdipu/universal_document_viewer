import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/word.dart';

/// [docx] with its `word/document.xml` replaced by [xml].
Uint8List _withDocumentXml(Uint8List docx, String xml) {
  final archive = ZipDecoder().decodeBytes(docx);
  final out = Archive();
  for (final file in archive.files) {
    out.addFile(
      file.name == 'word/document.xml'
          ? ArchiveFile.bytes(file.name, utf8.encode(xml))
          : ArchiveFile.bytes(file.name, file.content),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(out));
}

void main() {
  test('DTD entities are not expanded ("billion laughs")', () {
    const w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
    // Ten levels of ten: fully expanded, &lol9; would be 10^9 copies of "lol".
    final entities = StringBuffer('<!ENTITY lol0 "lol">');
    for (var i = 1; i < 10; i++) {
      entities.write('<!ENTITY lol$i "${List.filled(10, '&lol${i - 1};').join()}">');
    }
    final xml =
        '<?xml version="1.0"?><!DOCTYPE w:document [$entities]>'
        '<w:document xmlns:w="$w"><w:body><w:p><w:r><w:t>before &lol9; after</w:t></w:r></w:p></w:body></w:document>';
    final bytes = _withDocumentXml(buildDocx('<w:p/>'), xml);

    final watch = Stopwatch()..start();
    Object? result;
    try {
      result = DocxReader.read(bytes);
    } catch (e) {
      result = e; // Refusing the document is fine too; expanding it is not.
    }
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    if (result is WordDocument) {
      final text = result.body.whereType<WordParagraph>().map((p) => p.plainText).join();
      expect(text.length, lessThan(1000), reason: 'the entity was not expanded');
    }
  });
}
