import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Builds a minimal `.pptx` for tests (CR-OPENREADER-PPTX): just the parts
/// `PptxParser` reads - presentation.xml + its rels, the slides + their
/// rels, and media. [slides] are slide-tree bodies (`p:spTree` children), in
/// presentation order; they're stored in *reverse* file-name order so a test
/// can tell `p:sldIdLst` order from file order. [slideSize] (EMUs) writes
/// a `p:sldSz`.
Uint8List buildPptx(
  List<String> slides, {
  Map<String, List<int>> media = const {},
  Map<int, String> slideRels = const {},
  (int, int)? slideSize,
}) {
  const ns =
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  final archive = Archive();
  void add(String name, List<int> bytes) => archive.addFile(ArchiveFile.bytes(name, bytes));
  void addText(String name, String text) => add(name, utf8.encode(text));

  String fileFor(int index) => 'slide${slides.length - index}.xml';

  addText(
    'ppt/presentation.xml',
    '<?xml version="1.0" encoding="UTF-8"?><p:presentation $ns><p:sldIdLst>'
        '${[for (var i = 0; i < slides.length; i++) '<p:sldId id="${256 + i}" r:id="rId${i + 1}"/>'].join()}'
        '</p:sldIdLst>${slideSize == null ? '' : '<p:sldSz cx="${slideSize.$1}" cy="${slideSize.$2}"/>'}</p:presentation>',
  );
  addText(
    'ppt/_rels/presentation.xml.rels',
    '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[for (var i = 0; i < slides.length; i++) '<Relationship Id="rId${i + 1}" Type="slide" Target="slides/${fileFor(i)}"/>'].join()}'
        '</Relationships>',
  );
  for (var i = 0; i < slides.length; i++) {
    addText(
      'ppt/slides/${fileFor(i)}',
      '<?xml version="1.0" encoding="UTF-8"?><p:sld $ns><p:cSld><p:spTree>${slides[i]}</p:spTree></p:cSld></p:sld>',
    );
    if (slideRels[i] case final rels?) {
      addText(
        'ppt/slides/_rels/${fileFor(i)}.rels',
        '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>',
      );
    }
  }
  media.forEach((name, bytes) => add('ppt/media/$name', bytes));
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

String titleShape(String text) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
    '<p:txBody><a:p><a:r><a:t>$text</a:t></a:r></a:p></p:txBody></p:sp>';

/// A body shape; each entry is (text, bullet level).
String bodyShape(List<(String, int)> paragraphs) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
    '<p:txBody>${[for (final (text, level) in paragraphs) '<a:p><a:pPr lvl="$level"/><a:r><a:t>$text</a:t></a:r></a:p>'].join()}</p:txBody></p:sp>';

String tableFrame(List<List<String>> rows) =>
    '<p:graphicFrame><a:graphic><a:graphicData><a:tbl>'
    '${[
      for (final row in rows) '<a:tr>${[for (final cell in row) '<a:tc><a:txBody><a:p><a:r><a:t>$cell</a:t></a:r></a:p></a:txBody></a:tc>'].join()}</a:tr>',
    ].join()}'
    '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>';

String picture(String relId) => '<p:pic><p:blipFill><a:blip r:embed="$relId"/></p:blipFill></p:pic>';
