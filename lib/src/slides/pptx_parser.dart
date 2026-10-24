import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../engines/ooxml/opc_package.dart';

/// One piece of slide content, in reading order.
sealed class PptxBlock {
  const PptxBlock();
}

/// A text paragraph; [level] is the bullet indent (0 = top level).
class PptxParagraph extends PptxBlock {
  const PptxParagraph(this.text, {this.level = 0});

  final String text;
  final int level;
}

/// A table, as rows of cell text.
class PptxTable extends PptxBlock {
  const PptxTable(this.rows);

  final List<List<String>> rows;
}

/// A picture placed on the slide.
class PptxImage extends PptxBlock {
  const PptxImage(this.bytes);

  final Uint8List bytes;
}

class PptxSlide {
  const PptxSlide({this.title, this.blocks = const []});

  final String? title;
  final List<PptxBlock> blocks;

  /// Everything searchable on the slide.
  String get text => [
    if (title case final title?) title,
    for (final block in blocks)
      if (block is PptxParagraph)
        block.text
      else if (block is PptxTable)
        for (final row in block.rows) row.join(' '),
  ].join('\n');
}

class PptxPresentation {
  const PptxPresentation(this.slides, {this.slideWidth = 12192000, this.slideHeight = 6858000});

  final List<PptxSlide> slides;

  /// The slide size (`p:sldSz`) in EMUs; PowerPoint's 16:9 default when
  /// the file doesn't say.
  final int slideWidth;
  final int slideHeight;
}

/// Not a readable PowerPoint (.pptx) package.
class PptxFormatException implements Exception {
  const PptxFormatException(this.message);

  final String message;

  @override
  String toString() => 'PptxFormatException: $message';
}

/// Reads a `.pptx` (Office Open XML) into slides of text, tables and
/// pictures (CR-OPENREADER-PPTX). It is a reading view, not a layout engine:
/// positions, themes and animations are not reproduced.
class PptxParser {
  const PptxParser._();

  static const _ns = (
    p: 'http://schemas.openxmlformats.org/presentationml/2006/main',
    a: 'http://schemas.openxmlformats.org/drawingml/2006/main',
    r: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
  );

  /// Image types Flutter can decode; others (EMF/WMF vector art) are skipped.
  static const _imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'};

  /// Most pictures kept for a deck, counting each placement: a slide can
  /// place the same picture any number of times for a few bytes of XML.
  static const int maxPictures = 1000;

  /// Most picture bytes kept for a deck, each picture part counted once.
  /// Pictures past either cap are left out; the slides' text is not.
  static const int maxPictureBytes = 200 * 1024 * 1024;

  static PptxPresentation parse(Uint8List bytes) => _decode(bytes, null).deck;

  /// Just slide [wanted] (slide 1 when the deck has no such slide) and its
  /// index - for a thumbnail, which so reads only that slide's XML and
  /// pictures, not the whole deck's.
  static ({PptxPresentation deck, int index}) parseSlide(Uint8List bytes, int wanted) => _decode(bytes, wanted);

  static ({PptxPresentation deck, int index}) _decode(Uint8List bytes, int? only) {
    try {
      return _parse(OpcPackage.decode(bytes), only);
    } on OpcFormatException catch (e) {
      throw PptxFormatException(e.message);
    }
  }

  static ({PptxPresentation deck, int index}) _parse(OpcPackage package, int? only) {
    final presentationPath = package.mainPart ?? 'ppt/presentation.xml';
    final presentation = package.readXml(presentationPath);
    if (presentation == null) throw const PptxFormatException('No ppt/presentation.xml');
    final presentationRels = _targets(package, presentationPath);

    final slidePaths = <String>[
      for (final id in presentation.findAllElements('sldId', namespaceUri: _ns.p))
        if (presentationRels[id.getAttribute('id', namespaceUri: _ns.r)] case final target?) target,
    ];
    final index = only != null && only >= 0 && only < slidePaths.length ? only : 0;
    final wanted = only == null ? slidePaths : slidePaths.skip(index).take(1);

    final pictures = _Pictures(package);
    final slides = <PptxSlide>[];
    for (final path in wanted) {
      final xml = package.readXml(path);
      if (xml == null) continue;
      slides.add(_slide(xml, _targets(package, path), pictures));
    }
    final size = presentation.findAllElements('sldSz', namespaceUri: _ns.p).firstOrNull;
    final width = int.tryParse(size?.getAttribute('cx') ?? '') ?? 0;
    final height = int.tryParse(size?.getAttribute('cy') ?? '') ?? 0;
    if (width <= 0 || height <= 0) return (deck: PptxPresentation(slides), index: index);
    return (deck: PptxPresentation(slides, slideWidth: width, slideHeight: height), index: index);
  }

  /// Relationship id -> internal target part, for [part].
  static Map<String, String> _targets(OpcPackage package, String part) => {
        for (final rel in package.relationshipsOf(part))
          if (!rel.external) rel.id: rel.target,
      };

  static PptxSlide _slide(XmlDocument doc, Map<String, String> rels, _Pictures pictures) {
    String? title;
    final blocks = <PptxBlock>[];
    final tree = doc.findAllElements('spTree', namespaceUri: _ns.p).firstOrNull;
    if (tree == null) return const PptxSlide();

    void visit(XmlElement element) {
      for (final child in element.childElements) {
        if (child.namespaceUri == _ns.p && child.localName == 'sp') {
          final paragraphs = _paragraphs(child);
          if (paragraphs.isEmpty) continue;
          if (title == null && _isTitle(child)) {
            title = paragraphs.map((para) => para.text).join(' ');
          } else {
            blocks.addAll(paragraphs);
          }
        } else if (child.namespaceUri == _ns.p && child.localName == 'grpSp') {
          visit(child);
        } else if (child.namespaceUri == _ns.p && child.localName == 'graphicFrame') {
          final table = child.findAllElements('tbl', namespaceUri: _ns.a).firstOrNull;
          if (table != null) {
            final rows = [
              for (final row in table.findElements('tr', namespaceUri: _ns.a))
                [for (final cell in row.findElements('tc', namespaceUri: _ns.a)) _text(cell).trim()],
            ];
            if (rows.any((row) => row.isNotEmpty)) blocks.add(PptxTable(rows));
          }
        } else if (child.namespaceUri == _ns.p && child.localName == 'pic') {
          final embed = child
              .findAllElements('blip', namespaceUri: _ns.a)
              .firstOrNull
              ?.getAttribute('embed', namespaceUri: _ns.r);
          final path = embed == null ? null : rels[embed];
          if (path != null && _imageExtensions.contains(p.posix.extension(path).toLowerCase())) {
            if (pictures.place(path) case final bytes?) blocks.add(PptxImage(bytes));
          }
        }
      }
    }

    visit(tree);
    return PptxSlide(title: title, blocks: blocks);
  }

  static bool _isTitle(XmlElement shape) {
    final type = shape.findAllElements('ph', namespaceUri: _ns.p).firstOrNull?.getAttribute('type');
    return type == 'title' || type == 'ctrTitle';
  }

  static List<PptxParagraph> _paragraphs(XmlElement shape) {
    final body = shape.findAllElements('txBody', namespaceUri: _ns.p).firstOrNull;
    if (body == null) return const [];
    return [
      for (final para in body.findElements('p', namespaceUri: _ns.a))
        if (_text(para).trim() case final text when text.isNotEmpty)
          PptxParagraph(text, level: _level(para.findElements('pPr', namespaceUri: _ns.a).firstOrNull)),
    ];
  }

  /// A paragraph's `lvl`, clamped to DrawingML's nine levels (0-8): any
  /// other number would indent the paragraph off the slide.
  static int _level(XmlElement? properties) =>
      (int.tryParse(properties?.getAttribute('lvl') ?? '') ?? 0).clamp(0, 8);

  /// Text runs (`a:t`) in order; line breaks (`a:br`) become newlines.
  static String _text(XmlElement element) {
    final buffer = StringBuffer();
    for (final node in element.descendantElements) {
      if (node.namespaceUri != _ns.a) continue;
      if (node.localName == 't') buffer.write(node.innerText);
      if (node.localName == 'br') buffer.write('\n');
    }
    return buffer.toString();
  }
}

/// A deck's pictures, each part read once: every placement of a picture
/// shares one buffer, so a picture placed hundreds of times costs its size
/// once. Enforces [PptxParser.maxPictures] and [PptxParser.maxPictureBytes].
class _Pictures {
  _Pictures(this._package);

  final OpcPackage _package;
  final Map<String, Uint8List?> _byPath = {};
  int _placed = 0;
  int _bytes = 0;

  /// The picture at [path] for one more placement; null when it is missing,
  /// empty, damaged or past a cap.
  Uint8List? place(String path) {
    if (_placed >= PptxParser.maxPictures) return null;
    final bytes = _byPath.putIfAbsent(path, () => _read(path));
    if (bytes != null) _placed++;
    return bytes;
  }

  Uint8List? _read(String path) {
    final Uint8List? bytes;
    try {
      bytes = _package.readBytes(path);
    } on OpcFormatException {
      return null; // A damaged picture leaves a gap, not an unreadable deck.
    }
    if (bytes == null || bytes.isEmpty || _bytes + bytes.length > PptxParser.maxPictureBytes) return null;
    _bytes += bytes.length;
    return bytes;
  }
}
