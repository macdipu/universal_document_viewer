import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../ooxml/opc_package.dart';
import 'word_model.dart';
import 'word_styles.dart';

/// The file isn't a readable `.docx`.
class DocxFormatException implements Exception {
  const DocxFormatException(this.message);
  final String message;

  @override
  String toString() => 'DocxFormatException: $message';
}

/// Reads a `.docx` (WordprocessingML, ECMA-376 Part 1 §17) into a
/// [WordDocument] for display.
///
/// Covers the main text, tables (spans, vertical merges, borders, shading,
/// table styles with their conditional formats), lists (numbered by the
/// document's own definitions), images (inline, anchored, VML), links (web
/// and in-document), fields (results shown, instructions hidden), headers,
/// footers, footnotes and endnotes, sections, text boxes and equations
/// (as text). Tracked changes show as accepted. Callers should check the
/// bytes with `ZipSafetyGuard` first, and can run this in a background
/// isolate: the result is plain data.
abstract final class DocxReader {
  static WordDocument read(Uint8List bytes) {
    try {
      return _DocxParser(OpcPackage.decode(bytes)).parse();
    } on OpcFormatException catch (e) {
      throw DocxFormatException(e.message);
    } on XmlException {
      throw const DocxFormatException('Malformed XML');
    }
  }
}

/// Image types Flutter decodes; others (EMF/WMF, TIFF) show as a
/// placeholder.
const _decodableImages = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'};

class _Field {
  String instruction = '';
  bool showingResult = false;
  WordLink? link;

  /// For a PAGE/NUMPAGES field: which, and the saved result collected
  /// instead of shown.
  PageFieldKind? pageKind;
  final saved = StringBuffer();
  RunFormat format = RunFormat.plain;
}

/// `PAGE` / `NUMPAGES` (with any switches) -> their kind.
PageFieldKind? _pageFieldKind(String instruction) {
  final name = instruction.trim().split(RegExp(r'\s+')).first.toUpperCase();
  return switch (name) { 'PAGE' => PageFieldKind.page, 'NUMPAGES' => PageFieldKind.pageCount, _ => null };
}

/// What the block parser needs about the part it's reading.
class _PartContext {
  _PartContext(this.path, this.relationships, {this.mainBody = false});

  final String path;

  /// The document's own body, the only place a paragraph's `w:sectPr` ends a
  /// section. Headers, footers and notes can't hold section breaks, and
  /// reading one there could pull in the header part being read (recursion).
  final bool mainBody;

  /// Relationship id -> target (part name, or external URI).
  final Map<String, OpcRelationship> relationships;
}

/// A table cell's position, for its table style's conditional formats.
class _CellContext {
  const _CellContext(this.style, this.run, this.fill);

  final TableStyle style;

  /// The table style's text formatting with this cell's conditional
  /// formats applied.
  final RunProps run;
  final int? fill;
}

class _DocxParser {
  _DocxParser(this.package);

  final OpcPackage package;
  late final WordTheme theme;
  late final WordStyles styles;
  late final WordNumbering numbering;

  final _images = <String, Uint8List>{};
  final _sections = <WordSection>[];

  /// Note id -> its mark, assigned in order of first reference.
  final _footnoteLabels = <String, String>{};
  final _endnoteLabels = <String, String>{};

  /// Open complex fields (`w:fldChar`), innermost last. They can span runs,
  /// links and even paragraphs, so this lives across the whole part.
  final _fields = <_Field>[];

  /// The note being read, so its `w:footnoteRef` can show its own mark.
  String? _currentNoteLabel;

  /// Text boxes open around the content being read. Word doesn't nest them,
  /// so a deep nest is a hostile file: past [_maxTextBoxDepth] the inner
  /// boxes are skipped rather than recursed into.
  int _textBoxDepth = 0;
  static const _maxTextBoxDepth = 8;

  /// Word's limit is 63 grid columns; spans and skipped columns beyond this
  /// are malformed, and the views allocate per column.
  static const _maxGridColumns = 64;

  WordDocument parse() {
    final documentPath = package.mainPart ?? 'word/document.xml';
    final document = package.readXml(documentPath);
    if (document == null || document.rootElement.localName != 'document') {
      throw const DocxFormatException('No document part');
    }
    final rels = package.relationshipsOf(documentPath);
    XmlDocument? partOfType(String kind) => switch (rels.where((r) => !r.external && r.isOfType(kind)).firstOrNull) {
          final rel? => package.readXml(rel.target),
          null => null,
        };
    theme = WordTheme.parse(partOfType('theme'));
    styles = WordStyles.parse(partOfType('styles'), theme);
    numbering = WordNumbering.parse(partOfType('numbering'), theme);

    final context = _context(documentPath, mainBody: true);
    final body = wChild(document.rootElement, 'body');
    final blocks = body == null ? <WordBlock>[] : _blocks(body, context);
    // The body's own sectPr describes the last section.
    _sections.add(_section(wChild(body, 'sectPr'), context));
    _fields.clear();

    final footnotes = _notes(rels, 'footnotes', 'footnote', _footnoteLabels);
    final endnotes = _notes(rels, 'endnotes', 'endnote', _endnoteLabels);
    return WordDocument(
      body: blocks,
      sections: _inheritHeadersAndFooters(_sections),
      footnotes: footnotes,
      endnotes: endnotes,
      images: _images,
      linkColor: theme.color('hlink') ?? 0xFF0563C1,
    );
  }

  _PartContext _context(String path, {bool mainBody = false}) =>
      _PartContext(path, {for (final rel in package.relationshipsOf(path)) rel.id: rel}, mainBody: mainBody);

  // --- Blocks ----------------------------------------------------------------

  List<WordBlock> _blocks(XmlElement container, _PartContext part, {_CellContext? cell}) {
    final blocks = <WordBlock>[];
    void walk(XmlElement parent) {
      for (final child in parent.childElements) {
        switch (child.localName) {
          case 'p':
            blocks.addAll(_paragraph(child, part, cell: cell));
          case 'tbl':
            blocks.add(_table(child, part));
          case 'sdt':
            if (wChild(child, 'sdtContent') case final content?) walk(content);
          case 'customXml' || 'ins' || 'moveTo':
            walk(child);
          case 'AlternateContent':
            if (_alternate(child) case final chosen?) walk(chosen);
        }
      }
    }

    walk(container);
    return blocks;
  }

  /// `mc:AlternateContent`: the first `mc:Choice` (they're for features
  /// newer readers support, which here means drawing content), else the
  /// `mc:Fallback`.
  XmlElement? _alternate(XmlElement element) =>
      element.childElements.where((e) => e.localName == 'Choice').firstOrNull ??
      element.childElements.where((e) => e.localName == 'Fallback').firstOrNull;

  /// A paragraph, plus any blocks it carries along: text boxes' content,
  /// anchored images, and a section break when it ends a section.
  List<WordBlock> _paragraph(XmlElement element, _PartContext part, {_CellContext? cell}) {
    final pPr = wChild(element, 'pPr');
    final direct = ParaProps()..read(pPr, theme);
    final (styleParagraph, styleRun) = styles.paragraphStyle(direct.styleId);

    final paragraph = styles.defaultParagraph.copy();
    if (cell != null) paragraph.overrideWith(cell.style.paragraph);
    paragraph.overrideWith(styleParagraph);
    final numId = direct.numId ?? styleParagraph.numId;
    final numLevel = direct.numLevel ?? styleParagraph.numLevel ?? 0;
    if (numId != null && numId != 0) {
      if (numbering.levelParagraph(numId, numLevel) case final levelProps?) paragraph.overrideWith(levelProps);
    }
    paragraph.overrideWith(direct);

    final run = styles.defaultRun.copy();
    if (cell != null) run.overrideWith(cell.run);
    run.overrideWith(styleRun);

    final carried = <WordBlock>[];
    final inlines = <WordInline>[];
    _inlines(element, part, run, inlines, carried, link: null);

    ListMarker? marker;
    if (numId != null && numId != 0) {
      final markRun = run.copy()..overrideWith(RunProps()..read(wChild(pPr, 'rPr'), theme));
      marker = numbering.next(numId, numLevel, markRun);
    }
    final outline = paragraph.outlineLevel;
    final result = <WordBlock>[
      WordParagraph(
        _mergeTexts(inlines),
        format: paragraph.build(),
        marker: marker,
        outlineLevel: outline != null && outline < 9 ? outline : null,
      ),
      ...carried,
    ];
    // Only a body paragraph ends a section: not one in a table cell or text
    // box, nor in a header, footer or note.
    if (wChild(pPr, 'sectPr') case final sectPr? when part.mainBody && cell == null && _textBoxDepth == 0) {
      _sections.add(_section(sectPr, part));
      result.add(WordSectionBreak(_sections.length - 1));
    }
    return result;
  }

  /// Walks a paragraph's (or a container's) inline content in order.
  void _inlines(
    XmlElement parent,
    _PartContext part,
    RunProps paragraphRun,
    List<WordInline> out,
    List<WordBlock> carried, {
    required WordLink? link,
  }) {
    for (final child in parent.childElements) {
      switch (child.localName) {
        case 'r':
          _run(child, part, paragraphRun, out, carried, link: link);
        case 'hyperlink':
          final target = switch (wAttr(child, 'id')) {
            final id? => part.relationships[id]?.target,
            null => null,
          };
          final anchor = wAttr(child, 'anchor');
          _inlines(child, part, paragraphRun, out, carried,
              link: target == null && anchor == null ? link : WordLink(url: target, anchor: anchor));
        case 'fldSimple':
          final instruction = wAttr(child, 'instr') ?? '';
          if (_pageFieldKind(instruction) case final kind?) {
            final saved = <WordInline>[];
            _inlines(child, part, paragraphRun, saved, carried, link: link);
            final texts = saved.whereType<WordText>();
            out.add(WordPageField(
              kind,
              fallback: texts.map((t) => t.text).join(),
              format: texts.firstOrNull?.format ?? paragraphRun.build(),
            ));
          } else {
            _inlines(child, part, paragraphRun, out, carried, link: _hyperlinkField(instruction) ?? link);
          }
        case 'ins' || 'smartTag' || 'customXml' || 'dir' || 'bdo' || 'moveTo':
          _inlines(child, part, paragraphRun, out, carried, link: link);
        case 'sdt':
          if (wChild(child, 'sdtContent') case final content?) {
            _inlines(content, part, paragraphRun, out, carried, link: link);
          }
        case 'AlternateContent':
          if (_alternate(child) case final chosen?) _inlines(chosen, part, paragraphRun, out, carried, link: link);
        case 'bookmarkStart':
          final name = wAttr(child, 'name');
          if (name != null && name != '_GoBack') out.add(WordBookmark(name));
        case 'oMath' || 'oMathPara':
          // Equations, as their text (no 2D layout).
          final text = child.descendantElements.where((e) => e.localName == 't').map((e) => e.innerText).join();
          if (text.isNotEmpty) out.add(WordText(text, format: (paragraphRun.copy()..italic = true).build()));
      }
    }
  }

  void _run(
    XmlElement element,
    _PartContext part,
    RunProps paragraphRun,
    List<WordInline> out,
    List<WordBlock> carried, {
    required WordLink? link,
  }) {
    final rPr = wChild(element, 'rPr');
    final props = paragraphRun.copy()
      ..toggleWith(styles.characterStyle(wAttr(wChild(rPr, 'rStyle'), 'val')))
      ..overrideWith(RunProps()..read(rPr, theme));
    final format = props.build();
    final hidden = props.hidden ?? false;

    bool visible() => !hidden && _fields.every((f) => f.showingResult);
    WordLink? currentLink() {
      for (final field in _fields.reversed) {
        if (field.link != null) return field.link;
      }
      return link;
    }

    void text(String value) {
      if (value.isEmpty || !visible()) return;
      // A page-number field's result is kept aside; the field itself is
      // added when it ends.
      if (_fields.lastOrNull case final field? when field.pageKind != null) {
        field.saved.write(value);
        return;
      }
      out.add(WordText(value, format: format, link: currentLink()));
    }

    void handle(XmlElement child) {
      switch (child.localName) {
        case 't':
          text(child.innerText);
        case 'tab' || 'ptab':
          if (visible()) out.add(WordTab(format: format));
        case 'br':
          if (visible()) {
            out.add(WordBreak(switch (wAttr(child, 'type')) {
              'page' => BreakKind.page,
              'column' => BreakKind.column,
              _ => BreakKind.line,
            }));
          }
        case 'cr':
          if (visible()) out.add(const WordBreak(BreakKind.line));
        case 'noBreakHyphen':
          text('\u2011');
        case 'softHyphen':
          text('\u00AD');
        case 'sym':
          text(_symbol(wAttr(child, 'char'), wAttr(child, 'font')));
        case 'fldChar':
          switch (wAttr(child, 'fldCharType')) {
            case 'begin':
              _fields.add(_Field());
            case 'separate':
              if (_fields.isNotEmpty) {
                final field = _fields.last
                  ..showingResult = true
                  ..format = format;
                field.link = _hyperlinkField(field.instruction);
                field.pageKind = _pageFieldKind(field.instruction);
              }
            case 'end':
              if (_fields.isNotEmpty) {
                final field = _fields.removeLast();
                if (field.pageKind case final kind? when visible()) {
                  out.add(WordPageField(kind, fallback: field.saved.toString(), format: field.format));
                }
              }
          }
        case 'instrText':
          if (_fields.isNotEmpty && !_fields.last.showingResult) _fields.last.instruction += child.innerText;
        case 'footnoteReference' || 'endnoteReference':
          if (!visible()) break;
          final id = wAttr(child, 'id');
          if (id == null) break;
          final footnote = child.localName == 'footnoteReference';
          final labels = footnote ? _footnoteLabels : _endnoteLabels;
          // A custom mark is the run text that follows; no number of its own.
          final custom = switch (wAttr(child, 'customMarkFollows')) { '1' || 'true' || 'on' => true, _ => false };
          final label = labels.putIfAbsent(
            id,
            () => custom
                ? ''
                : footnote
                    ? '${labels.length + 1}'
                    : WordNumbering.formatNumber(labels.length + 1, 'lowerRoman'),
          );
          out.add(WordNoteReference(
            kind: footnote ? NoteKind.footnote : NoteKind.endnote,
            id: id,
            label: label,
            format: format,
          ));
        case 'footnoteRef' || 'endnoteRef':
          // Inside a note: the note's own mark.
          text(_currentNoteLabel ?? '');
        case 'drawing':
          if (visible()) _drawing(child, part, out, carried);
        case 'pict' || 'object':
          if (visible()) _vml(child, part, out, carried);
        case 'AlternateContent':
          // The chosen branch is more of this run's content.
          _alternate(child)?.childElements.forEach(handle);
      }
    }

    element.childElements.forEach(handle);
  }

  /// `HYPERLINK "url"` or `HYPERLINK \l "bookmark"` -> a link.
  WordLink? _hyperlinkField(String? instruction) {
    if (instruction == null) return null;
    final match = RegExp(r'^\s*HYPERLINK\s+(.*)$', caseSensitive: false).firstMatch(instruction);
    if (match == null) return null;
    final args = match.group(1)!;
    final anchor = RegExp(r'\\l\s+"([^"]*)"').firstMatch(args)?.group(1);
    final url = RegExp(r'^\s*"([^"]*)"').firstMatch(args)?.group(1) ??
        RegExp(r'^\s*([^\s\\"]+)').firstMatch(args)?.group(1);
    if (url == null && anchor == null) return null;
    return WordLink(url: url, anchor: anchor);
  }

  /// `w:sym`: a character from a symbol font, mapped to its Unicode
  /// equivalent where the common ones are known.
  String _symbol(String? hex, String? font) {
    final code = int.tryParse(hex ?? '', radix: 16);
    if (code == null) return '';
    final low = code & 0xFF;
    if (font != null && (font.contains('Symbol') || font.contains('Wingdings'))) {
      return switch (low) {
        0xB7 => '•',
        0xA7 => '▪',
        0xFC => '✓',
        0xFB => '✗',
        0xE0 => '→',
        0xD8 => '➢',
        0x6F => '○',
        0xA8 => '☐',
        0xFE => '☑',
        _ => String.fromCharCode(low),
      };
    }
    return String.fromCharCode(code >= 0xF000 ? low : code);
  }

  // --- Images and text boxes -------------------------------------------------

  void _drawing(XmlElement drawing, _PartContext part, List<WordInline> out, List<WordBlock> carried) {
    for (final frame in drawing.childElements) {
      final floating = frame.localName == 'anchor';
      if (frame.localName != 'inline' && !floating) continue;
      final extent = wChild(frame, 'extent');
      final width = (double.tryParse(wAttr(extent, 'cx') ?? '') ?? 0) / 12700;
      final height = (double.tryParse(wAttr(extent, 'cy') ?? '') ?? 0) / 12700;
      final docPr = wChild(frame, 'docPr');
      final description = wAttr(docPr, 'descr') ?? wAttr(docPr, 'title');
      final blip = _outsideTextBoxes(frame, 'blip').firstOrNull;
      final embed = wAttr(blip, 'embed');
      if (embed != null) {
        final image = _image(embed, part, width, height, description, floating);
        if (image != null) floating ? carried.add(WordParagraph([image])) : out.add(image);
      }
      // Shapes and text boxes: their text, as blocks after the paragraph.
      _textBoxes(frame, part, carried);
    }
  }

  /// The text boxes directly in [shape], read as blocks into [carried].
  /// Boxes nested inside them are read by their own box's paragraphs, so
  /// they're not visited here: visiting every descendant box made each
  /// level read the ones below it again, doubling the work per level.
  void _textBoxes(XmlElement shape, _PartContext part, List<WordBlock> carried) {
    if (_textBoxDepth >= _maxTextBoxDepth) return;
    _textBoxDepth++;
    try {
      for (final box in _outsideTextBoxes(shape, 'txbxContent')) {
        carried.addAll(_blocks(box, part));
      }
    } finally {
      _textBoxDepth--;
    }
  }

  /// Elements named [name] under [root], in document order, without looking
  /// inside text boxes (`w:txbxContent`, itself yielded when asked for):
  /// what's in a box belongs to the box. Iterative, as a hostile file can
  /// nest deeply.
  static Iterable<XmlElement> _outsideTextBoxes(XmlElement root, String name) sync* {
    final stack = root.childElements.toList().reversed.toList();
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      if (element.localName == name) yield element;
      if (element.localName != 'txbxContent') stack.addAll(element.childElements.toList().reversed);
    }
  }

  /// Legacy VML pictures (`w:pict`, `w:object` previews).
  void _vml(XmlElement element, _PartContext part, List<WordInline> out, List<WordBlock> carried) {
    final imageData = _outsideTextBoxes(element, 'imagedata').firstOrNull;
    final id = wAttr(imageData, 'id');
    if (id != null) {
      final shape = imageData!.parentElement;
      final style = wAttr(shape, 'style') ?? '';
      double size(String name) {
        final match = RegExp('$name:\\s*([\\d.]+)(pt|in|px|cm|mm)?').firstMatch(style);
        final value = double.tryParse(match?.group(1) ?? '') ?? 0;
        return switch (match?.group(2)) {
          'in' => value * 72,
          'px' => value * 0.75,
          'cm' => value * 72 / 2.54,
          'mm' => value * 72 / 25.4,
          _ => value,
        };
      }

      final image = _image(id, part, size('width'), size('height'), wAttr(shape, 'alt'), false);
      if (image != null) out.add(image);
    }
    _textBoxes(element, part, carried);
  }

  WordImage? _image(String relationshipId, _PartContext part, double width, double height, String? description,
      bool floating) {
    final rel = part.relationships[relationshipId];
    if (rel == null || rel.external) return null;
    final target = rel.target;
    if (!_images.containsKey(target) && _decodableImages.contains(p.posix.extension(target).toLowerCase())) {
      final bytes = package.readBytes(target);
      if (bytes != null) _images[target] = bytes;
    }
    return WordImage(part: target, width: width, height: height, description: description, floating: floating);
  }

  // --- Tables ------------------------------------------------------------------

  WordTable _table(XmlElement element, _PartContext part) {
    final tblPr = wChild(element, 'tblPr');
    final style = styles.tableStyle(wAttr(wChild(tblPr, 'tblStyle'), 'val'));
    final look = _TableLook.read(wChild(tblPr, 'tblLook'));

    var borders = style.borders;
    var insideH = style.insideHorizontal;
    var insideV = style.insideVertical;
    if (wChild(tblPr, 'tblBorders') case final direct?) {
      borders = CellBorders(
        top: readBorder(wChild(direct, 'top'), theme) ?? borders.top,
        bottom: readBorder(wChild(direct, 'bottom'), theme) ?? borders.bottom,
        left: readBorder(wChild(direct, 'left') ?? wChild(direct, 'start'), theme) ?? borders.left,
        right: readBorder(wChild(direct, 'right') ?? wChild(direct, 'end'), theme) ?? borders.right,
      );
      insideH = readBorder(wChild(direct, 'insideH'), theme) ?? insideH;
      insideV = readBorder(wChild(direct, 'insideV'), theme) ?? insideV;
    }

    final columnWidths = [
      for (final column in wChildren(wChild(element, 'tblGrid'), 'gridCol')) twips(wAttr(column, 'w')) ?? 0,
    ];

    // Rows may sit inside content controls or tracked insertions.
    final rowElements = <XmlElement>[];
    void collectRows(XmlElement parent) {
      for (final child in parent.childElements) {
        switch (child.localName) {
          case 'tr':
            rowElements.add(child);
          case 'sdt':
            if (wChild(child, 'sdtContent') case final content?) collectRows(content);
          case 'customXml' || 'ins':
            collectRows(child);
        }
      }
    }

    collectRows(element);

    final rowCount = rowElements.length;
    final gridCount = columnWidths.isEmpty ? null : columnWidths.length;
    final drafts = <List<_CellDraft>>[];
    // Grid column -> the cell (row, index) a vertical merge started at.
    final mergeOrigins = <int, _CellDraft>{};

    for (var r = 0; r < rowCount; r++) {
      final cellElements = <XmlElement>[];
      void collectCells(XmlElement parent) {
        for (final child in parent.childElements) {
          switch (child.localName) {
            case 'tc':
              cellElements.add(child);
            case 'sdt':
              if (wChild(child, 'sdtContent') case final content?) collectCells(content);
            case 'customXml' || 'ins':
              collectCells(child);
          }
        }
      }

      collectCells(rowElements[r]);
      final row = <_CellDraft>[];
      final gridBefore = int.tryParse(wAttr(wChild(wChild(rowElements[r], 'trPr'), 'gridBefore'), 'val') ?? '') ?? 0;
      var gridColumn = gridBefore.clamp(0, _maxGridColumns);
      final lastGridColumn = (gridCount ?? 0) - 1;
      for (var c = 0; c < cellElements.length; c++) {
        final tc = cellElements[c];
        final tcPr = wChild(tc, 'tcPr');
        // A span below one would break the column arithmetic; a huge one
        // makes the views lay out (and allocate for) that many columns.
        final gridSpan = int.tryParse(wAttr(wChild(tcPr, 'gridSpan'), 'val') ?? '') ?? 1;
        final span = gridSpan < 1 ? 1 : math.min(gridSpan, math.min(gridCount ?? _maxGridColumns, _maxGridColumns));
        final vMerge = wChild(tcPr, 'vMerge');
        final continues = vMerge != null && wAttr(vMerge, 'val') != 'restart';

        final conditional = _conditional(
          style,
          look,
          row: r,
          rowCount: rowCount,
          firstColumn: gridColumn,
          lastColumn: gridColumn + span - 1,
          lastGridColumn: gridCount == null ? cellElements.length - 1 : lastGridColumn,
        );
        final directFill = switch (wChild(tcPr, 'shd')) {
          final shd? => readShading(shd, theme),
          null => null,
        };

        final cellBorders = _cellBorders(
          wChild(tcPr, 'tcBorders'),
          table: borders,
          insideH: insideH,
          insideV: insideV,
          firstRow: r == 0,
          lastRow: r == rowCount - 1,
          firstColumn: gridColumn == 0,
          lastColumn: gridCount == null ? c == cellElements.length - 1 : gridColumn + span - 1 >= lastGridColumn,
        );
        final draft = _CellDraft(
          blocks: continues ? const [] : _blocks(tc, part, cell: conditional),
          columnSpan: span,
          covered: continues,
          fill: directFill ?? conditional.fill,
          verticalAlignment: switch (wAttr(wChild(tcPr, 'vAlign'), 'val')) {
            'center' => CellVerticalAlignment.center,
            'bottom' => CellVerticalAlignment.bottom,
            _ => CellVerticalAlignment.top,
          },
          borders: cellBorders,
        );
        if (continues) {
          mergeOrigins[gridColumn]?.rowSpan++;
        } else if (vMerge != null) {
          mergeOrigins[gridColumn] = draft;
        } else {
          mergeOrigins.remove(gridColumn);
        }
        row.add(draft);
        gridColumn += span;
      }
      drafts.add(row);
    }

    return WordTable(
      columnWidths: columnWidths,
      alignment: switch (wAttr(wChild(tblPr, 'jc'), 'val')) {
        'center' => ParagraphAlignment.center,
        'right' || 'end' => ParagraphAlignment.right,
        _ => ParagraphAlignment.left,
      },
      rows: [
        for (var r = 0; r < rowCount; r++)
          WordTableRow(
            [for (final draft in drafts[r]) draft.build()],
            isHeader: wOnOff(wChild(wChild(rowElements[r], 'trPr'), 'tblHeader')) ?? false,
            height: twips(wAttr(wChild(wChild(rowElements[r], 'trPr'), 'trHeight'), 'val')),
          ),
      ],
    );
  }

  /// A cell's text formatting and fill from its table style's conditional
  /// formats, lowest priority first (§17.7.6).
  _CellContext _conditional(
    TableStyle style,
    _TableLook look, {
    required int row,
    required int rowCount,
    required int firstColumn,
    required int lastColumn,
    required int lastGridColumn,
  }) {
    final types = <String>[];
    final headerRows = look.firstRow ? 1 : 0;
    if (look.verticalBanding) types.add((firstColumn - (look.firstColumn ? 1 : 0)).isEven ? 'band1Vert' : 'band2Vert');
    if (look.horizontalBanding && !(look.firstRow && row == 0) && !(look.lastRow && row == rowCount - 1)) {
      types.add((row - headerRows).isEven ? 'band1Horz' : 'band2Horz');
    }
    if (look.firstColumn && firstColumn == 0) types.add('firstCol');
    if (look.lastColumn && lastColumn >= lastGridColumn) types.add('lastCol');
    if (look.firstRow && row == 0) types.add('firstRow');
    if (look.lastRow && row == rowCount - 1) types.add('lastRow');
    final run = style.run.copy();
    int? fill;
    for (final type in types) {
      final conditional = style.conditional[type];
      if (conditional == null) continue;
      run.overrideWith(conditional.run);
      fill = conditional.fill ?? fill;
    }
    return _CellContext(style, run, fill);
  }

  CellBorders _cellBorders(
    XmlElement? tcBorders, {
    required CellBorders table,
    required BorderLine? insideH,
    required BorderLine? insideV,
    required bool firstRow,
    required bool lastRow,
    required bool firstColumn,
    required bool lastColumn,
  }) {
    BorderLine? side(String name, String alternate, BorderLine? fallback) =>
        readBorder(wChild(tcBorders, name) ?? wChild(tcBorders, alternate), theme) ?? fallback;
    return CellBorders(
      top: side('top', 'top', firstRow ? table.top : insideH),
      bottom: side('bottom', 'bottom', lastRow ? table.bottom : insideH),
      left: side('left', 'start', firstColumn ? table.left : insideV),
      right: side('right', 'end', lastColumn ? table.right : insideV),
    );
  }

  // --- Sections, headers, footers, notes ----------------------------------

  WordSection _section(XmlElement? sectPr, _PartContext part) {
    final size = wChild(sectPr, 'pgSz');
    final margins = wChild(sectPr, 'pgMar');
    Map<HeaderFooterKind, List<WordBlock>> parts(String reference) => {
          for (final ref in wChildren(sectPr, reference))
            if (part.relationships[wAttr(ref, 'id')] case final rel? when !rel.external)
              _kind(wAttr(ref, 'type')): _headerFooter(rel.target),
        };
    final landscape = wAttr(size, 'orient') == 'landscape';
    // Pages between half an inch and Word's 22 inches, margins within the
    // page: a malformed size would otherwise lay out absurd (or no) pages.
    var width = (twips(wAttr(size, 'w')) ?? 612).clamp(_minPageSize, _maxPageSize);
    var height = (twips(wAttr(size, 'h')) ?? 792).clamp(_minPageSize, _maxPageSize);
    if (landscape && width < height) (width, height) = (height, width);
    double margin(String? value, double page) => (twips(value) ?? 72).abs().clamp(0.0, page);
    return WordSection(
      pageWidth: width,
      pageHeight: height,
      marginTop: margin(wAttr(margins, 'top'), height),
      marginBottom: margin(wAttr(margins, 'bottom'), height),
      marginLeft: margin(wAttr(margins, 'left') ?? wAttr(margins, 'start'), width),
      marginRight: margin(wAttr(margins, 'right') ?? wAttr(margins, 'end'), width),
      headers: parts('headerReference'),
      footers: parts('footerReference'),
      titlePage: wOnOff(wChild(sectPr, 'titlePg')) ?? false,
    );
  }

  static const double _minPageSize = 36;
  static const double _maxPageSize = 1584;

  static HeaderFooterKind _kind(String? type) => switch (type) {
        'first' => HeaderFooterKind.first,
        'even' => HeaderFooterKind.even,
        _ => HeaderFooterKind.defaultKind,
      };

  final _headerFooterCache = <String, List<WordBlock>>{};

  List<WordBlock> _headerFooter(String path) => _headerFooterCache.putIfAbsent(path, () {
        final doc = package.readXml(path);
        if (doc == null) return const [];
        final saved = List.of(_fields);
        _fields.clear();
        final blocks = _blocks(doc.rootElement, _context(path));
        _fields
          ..clear()
          ..addAll(saved);
        return blocks;
      });

  /// A section without its own header/footer of a kind uses the previous
  /// section's (§17.10.5).
  List<WordSection> _inheritHeadersAndFooters(List<WordSection> sections) {
    final result = <WordSection>[];
    for (final section in sections) {
      final previous = result.isEmpty ? null : result.last;
      result.add(WordSection(
        pageWidth: section.pageWidth,
        pageHeight: section.pageHeight,
        marginTop: section.marginTop,
        marginBottom: section.marginBottom,
        marginLeft: section.marginLeft,
        marginRight: section.marginRight,
        headers: {...?previous?.headers, ...section.headers},
        footers: {...?previous?.footers, ...section.footers},
        titlePage: section.titlePage,
      ));
    }
    return result;
  }

  /// Footnotes or endnotes that the text refers to, in reference order.
  Map<String, List<WordBlock>> _notes(
      List<OpcRelationship> rels, String kind, String element, Map<String, String> labels) {
    if (labels.isEmpty) return const {};
    final rel = rels.where((r) => !r.external && r.isOfType(kind)).firstOrNull;
    final doc = rel == null ? null : package.readXml(rel.target);
    if (doc == null) return const {};
    final context = _context(rel!.target);
    final byId = {
      for (final note in wChildren(doc.rootElement, element))
        if (wAttr(note, 'id') case final id?) id: note,
    };
    final notes = <String, List<WordBlock>>{};
    // A note can refer to another note, which numbers it (adds to [labels])
    // while this walks them: work through a list that grows to match.
    final pending = labels.keys.toList();
    for (var i = 0; i < pending.length; i++) {
      final id = pending[i];
      final note = byId[id];
      if (note != null) {
        _currentNoteLabel = labels[id];
        notes[id] = _blocks(note, context);
        _fields.clear();
      }
      if (labels.length > pending.length) pending.addAll(labels.keys.skip(pending.length));
    }
    _currentNoteLabel = null;
    return notes;
  }

  /// Adjacent text with the same formatting and link becomes one piece:
  /// fewer spans to lay out.
  static List<WordInline> _mergeTexts(List<WordInline> inlines) {
    final merged = <WordInline>[];
    for (final inline in inlines) {
      final previous = merged.isEmpty ? null : merged.last;
      if (inline is WordText && previous is WordText && previous.format == inline.format && previous.link == inline.link) {
        merged[merged.length - 1] = WordText(previous.text + inline.text, format: inline.format, link: inline.link);
      } else {
        merged.add(inline);
      }
    }
    return merged;
  }
}

class _CellDraft {
  _CellDraft({
    required this.blocks,
    required this.columnSpan,
    required this.covered,
    required this.fill,
    required this.verticalAlignment,
    required this.borders,
  });

  final List<WordBlock> blocks;
  final int columnSpan;
  final bool covered;
  final int? fill;
  final CellVerticalAlignment verticalAlignment;
  final CellBorders borders;
  int rowSpan = 1;

  WordTableCell build() => WordTableCell(
        blocks,
        columnSpan: columnSpan,
        rowSpan: rowSpan,
        covered: covered,
        fill: fill,
        verticalAlignment: verticalAlignment,
        borders: borders,
      );
}

/// `w:tblLook`: which of a table style's conditional formats apply. Both
/// the attribute form and the older hex `val` form (§17.4.56).
class _TableLook {
  const _TableLook({
    this.firstRow = true,
    this.lastRow = false,
    this.firstColumn = true,
    this.lastColumn = false,
    this.horizontalBanding = true,
    this.verticalBanding = false,
  });

  final bool firstRow;
  final bool lastRow;
  final bool firstColumn;
  final bool lastColumn;
  final bool horizontalBanding;
  final bool verticalBanding;

  factory _TableLook.read(XmlElement? look) {
    if (look == null) return const _TableLook();
    bool? flag(String name) => switch (wAttr(look, name)) {
          null => null,
          final v => v == '1' || v == 'true' || v == 'on',
        };
    final hex = int.tryParse(wAttr(look, 'val') ?? '', radix: 16) ?? 0;
    bool bit(int mask) => hex & mask != 0;
    return _TableLook(
      firstRow: flag('firstRow') ?? bit(0x0020),
      lastRow: flag('lastRow') ?? bit(0x0040),
      firstColumn: flag('firstColumn') ?? bit(0x0080),
      lastColumn: flag('lastColumn') ?? bit(0x0100),
      horizontalBanding: !(flag('noHBand') ?? bit(0x0200)),
      verticalBanding: !(flag('noVBand') ?? bit(0x0400)),
    );
  }
}
