import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _r = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// Builds a minimal `.docx` for tests: [body] is the `w:body` content (the
/// `w:` and `r:` prefixes are declared), and [styles], [numbering],
/// [footnotes] and [endnotes] are the inner XML of those parts when given.
/// [relationships] adds `Relationship` elements to the document's rels;
/// [media] adds files under `word/`.
Uint8List buildDocx(
  String body, {
  String? styles,
  String? numbering,
  String? footnotes,
  String? endnotes,
  String relationships = '',
  Map<String, List<int>> media = const {},
}) {
  final archive = Archive();
  void add(String name, String text) => archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
  String part(String root, String inner) =>
      '<?xml version="1.0" encoding="UTF-8"?><w:$root xmlns:w="$_w" xmlns:r="$_r">$inner</w:$root>';

  add('_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="$_r/officeDocument" Target="word/document.xml"/></Relationships>');
  add('word/document.xml', part('document', '<w:body>$body</w:body>'));
  final rels = StringBuffer(relationships);
  void link(String id, String type, String target, String? inner, String root) {
    if (inner == null) return;
    add('word/$target', part(root, inner));
    rels.write('<Relationship Id="$id" Type="$_r/$type" Target="$target"/>');
  }

  link('rIdStyles', 'styles', 'styles.xml', styles, 'styles');
  link('rIdNumbering', 'numbering', 'numbering.xml', numbering, 'numbering');
  link('rIdFootnotes', 'footnotes', 'footnotes.xml', footnotes, 'footnotes');
  link('rIdEndnotes', 'endnotes', 'endnotes.xml', endnotes, 'endnotes');
  add('word/_rels/document.xml.rels',
      '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>');
  media.forEach((name, bytes) => archive.addFile(ArchiveFile.bytes('word/$name', bytes)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}
