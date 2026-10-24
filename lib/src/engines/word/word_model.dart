import 'dart:typed_data';

/// A Word document as read from a `.docx`, ready to display: styles are
/// already resolved onto every paragraph and run, list markers are already
/// numbered, and field codes are reduced to their shown results.
///
/// Plain data all the way down, so a document parsed in a background
/// isolate can be sent back to the UI isolate.
class WordDocument {
  const WordDocument({
    required this.body,
    this.sections = const [WordSection()],
    this.footnotes = const {},
    this.endnotes = const {},
    this.images = const {},
    this.linkColor = 0xFF0563C1,
  });

  /// The main text. [WordSectionBreak]s mark where each of [sections]
  /// ends (the last section ends with the body).
  final List<WordBlock> body;

  /// Page setup and headers/footers, one per section, in order.
  final List<WordSection> sections;

  /// Note text by note id; [WordNoteReference.id] points here.
  final Map<String, List<WordBlock>> footnotes;
  final Map<String, List<WordBlock>> endnotes;

  /// Image bytes by package part name; [WordImage.part] points here.
  final Map<String, Uint8List> images;

  /// The theme's hyperlink colour (0xAARRGGBB), for links whose text has
  /// no colour of its own.
  final int linkColor;
}

/// A section's page and its headers/footers. Sizes are in points.
class WordSection {
  const WordSection({
    this.pageWidth = 612,
    this.pageHeight = 792,
    this.marginTop = 72,
    this.marginBottom = 72,
    this.marginLeft = 72,
    this.marginRight = 72,
    this.headers = const {},
    this.footers = const {},
    this.titlePage = false,
  });

  final double pageWidth;
  final double pageHeight;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  final Map<HeaderFooterKind, List<WordBlock>> headers;
  final Map<HeaderFooterKind, List<WordBlock>> footers;

  /// Whether the first page uses the [HeaderFooterKind.first] header/footer.
  final bool titlePage;
}

enum HeaderFooterKind { defaultKind, first, even }

// --- Blocks ----------------------------------------------------------------

sealed class WordBlock {
  const WordBlock();
}

class WordParagraph extends WordBlock {
  const WordParagraph(this.inlines, {this.format = ParagraphFormat.plain, this.marker, this.outlineLevel});

  final List<WordInline> inlines;
  final ParagraphFormat format;

  /// The list number or bullet in front of the paragraph, if it's a list
  /// item.
  final ListMarker? marker;

  /// 0 for a level-1 heading, 1 for level 2...; null for body text.
  final int? outlineLevel;

  /// The paragraph's text as shown, for search and accessibility: tabs as
  /// `\t`, line breaks as `\n`, notes as their number.
  String get plainText {
    final buffer = StringBuffer();
    for (final inline in inlines) {
      buffer.write(inline.plainText);
    }
    return buffer.toString();
  }
}

class WordTable extends WordBlock {
  const WordTable({required this.rows, this.columnWidths = const [], this.alignment = ParagraphAlignment.left});

  /// Widths of the table's grid columns in points (`w:tblGrid`); cells span
  /// one or more of these.
  final List<double> columnWidths;
  final List<WordTableRow> rows;
  final ParagraphAlignment alignment;
}

class WordTableRow {
  const WordTableRow(this.cells, {this.isHeader = false, this.height});

  final List<WordTableCell> cells;

  /// Repeats at the top of each page in a paged layout.
  final bool isHeader;

  /// Minimum height in points, or null for automatic.
  final double? height;
}

class WordTableCell {
  const WordTableCell(
    this.blocks, {
    this.columnSpan = 1,
    this.rowSpan = 1,
    this.covered = false,
    this.fill,
    this.verticalAlignment = CellVerticalAlignment.top,
    this.borders = CellBorders.none,
  });

  final List<WordBlock> blocks;

  /// Grid columns this cell spans (`w:gridSpan`).
  final int columnSpan;

  /// Rows this cell spans, from vertical merges (`w:vMerge`). The cells it
  /// covers in later rows are kept, [covered], so each row still accounts
  /// for every grid column.
  final int rowSpan;
  final bool covered;

  /// Background as 0xAARRGGBB, or null.
  final int? fill;
  final CellVerticalAlignment verticalAlignment;
  final CellBorders borders;
}

enum CellVerticalAlignment { top, center, bottom }

/// A line on one side of a cell or paragraph.
class BorderLine {
  const BorderLine({this.width = 0.5, this.color});

  /// In points.
  final double width;

  /// 0xAARRGGBB, or null for automatic (the text colour).
  final int? color;
}

class CellBorders {
  const CellBorders({this.top, this.bottom, this.left, this.right});

  static const none = CellBorders();

  final BorderLine? top;
  final BorderLine? bottom;
  final BorderLine? left;
  final BorderLine? right;
}

/// Where one section ends and the next begins.
class WordSectionBreak extends WordBlock {
  const WordSectionBreak(this.sectionIndex);

  /// Index into [WordDocument.sections] of the section that just ended.
  final int sectionIndex;
}

// --- Inline content ----------------------------------------------------------

sealed class WordInline {
  const WordInline();

  /// How this reads in [WordParagraph.plainText].
  String get plainText;
}

class WordText extends WordInline {
  const WordText(this.text, {this.format = RunFormat.plain, this.link});

  final String text;
  final RunFormat format;
  final WordLink? link;

  @override
  String get plainText => text;
}

class WordTab extends WordInline {
  const WordTab({this.format = RunFormat.plain});
  final RunFormat format;

  @override
  String get plainText => '\t';
}

enum BreakKind { line, page, column }

class WordBreak extends WordInline {
  const WordBreak(this.kind);
  final BreakKind kind;

  @override
  String get plainText => '\n';
}

class WordImage extends WordInline {
  const WordImage({required this.part, required this.width, required this.height, this.description, this.floating = false});

  /// Key into [WordDocument.images].
  final String part;

  /// Display size in points.
  final double width;
  final double height;

  /// Alt text.
  final String? description;

  /// Anchored (floating) rather than inline; shown on a line of its own.
  final bool floating;

  @override
  String get plainText => '';
}

enum NoteKind { footnote, endnote }

class WordNoteReference extends WordInline {
  const WordNoteReference({required this.kind, required this.id, required this.label, this.format = RunFormat.plain});

  final NoteKind kind;

  /// Key into [WordDocument.footnotes] / [WordDocument.endnotes].
  final String id;

  /// The mark shown: `1`, `2`... for footnotes, `i`, `ii`... for endnotes.
  final String label;
  final RunFormat format;

  @override
  String get plainText => label;
}

enum PageFieldKind { page, pageCount }

/// A `PAGE` or `NUMPAGES` field: the page number (or count) where it's
/// shown. [fallback] is the result Word saved, for views without pages.
class WordPageField extends WordInline {
  const WordPageField(this.kind, {this.fallback = '', this.format = RunFormat.plain});

  final PageFieldKind kind;
  final String fallback;
  final RunFormat format;

  @override
  String get plainText => fallback;
}

/// A named place a link can jump to (`w:bookmarkStart`).
class WordBookmark extends WordInline {
  const WordBookmark(this.name);
  final String name;

  @override
  String get plainText => '';
}

/// A link's target: a web address, or a bookmark in this document.
class WordLink {
  const WordLink({this.url, this.anchor});

  final String? url;
  final String? anchor;

  @override
  bool operator ==(Object other) => other is WordLink && other.url == url && other.anchor == anchor;

  @override
  int get hashCode => Object.hash(url, anchor);
}

// --- Formatting --------------------------------------------------------------

enum ParagraphAlignment { left, center, right, justify }

enum LineSpacingRule {
  /// [ParagraphFormat.lineSpacing] is a multiple of single spacing.
  auto,

  /// In points, exactly.
  exact,

  /// In points, at least.
  atLeast,
}

/// A paragraph's resolved formatting. Lengths in points.
class ParagraphFormat {
  const ParagraphFormat({
    this.alignment = ParagraphAlignment.left,
    this.indentLeft = 0,
    this.indentRight = 0,
    this.firstLineIndent = 0,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
    this.lineSpacing = 1,
    this.lineSpacingRule = LineSpacingRule.auto,
    this.fill,
    this.borderTop,
    this.borderBottom,
    this.borderLeft,
    this.borderRight,
    this.pageBreakBefore = false,
    this.keepWithNext = false,
    this.rightToLeft = false,
  });

  static const plain = ParagraphFormat();

  final ParagraphAlignment alignment;
  final double indentLeft;
  final double indentRight;

  /// Positive for a first-line indent, negative for a hanging indent.
  final double firstLineIndent;
  final double spaceBefore;
  final double spaceAfter;
  final double lineSpacing;
  final LineSpacingRule lineSpacingRule;

  /// Background as 0xAARRGGBB, or null.
  final int? fill;
  final BorderLine? borderTop;
  final BorderLine? borderBottom;
  final BorderLine? borderLeft;
  final BorderLine? borderRight;
  final bool pageBreakBefore;
  final bool keepWithNext;
  final bool rightToLeft;

  /// The same formatting with different spacing (for the two pieces of a
  /// paragraph split across pages).
  ParagraphFormat withSpacing({double? before, double? after}) => ParagraphFormat(
        alignment: alignment,
        indentLeft: indentLeft,
        indentRight: indentRight,
        firstLineIndent: firstLineIndent,
        spaceBefore: before ?? spaceBefore,
        spaceAfter: after ?? spaceAfter,
        lineSpacing: lineSpacing,
        lineSpacingRule: lineSpacingRule,
        fill: fill,
        borderTop: borderTop,
        borderBottom: borderBottom,
        borderLeft: borderLeft,
        borderRight: borderRight,
        pageBreakBefore: pageBreakBefore,
        keepWithNext: keepWithNext,
        rightToLeft: rightToLeft,
      );
}

enum UnderlineStyle { none, single, double, dotted, dashed, wavy }

enum VerticalTextPosition { baseline, superscript, subscript }

/// A run's resolved formatting. Sizes in points.
class RunFormat {
  const RunFormat({
    this.bold = false,
    this.italic = false,
    this.underline = UnderlineStyle.none,
    this.strike = false,
    this.doubleStrike = false,
    this.color,
    this.highlight,
    this.fill,
    this.size = 11,
    this.font,
    this.verticalPosition = VerticalTextPosition.baseline,
    this.allCaps = false,
    this.smallCaps = false,
    this.letterSpacing = 0,
  });

  static const plain = RunFormat();

  final bool bold;
  final bool italic;
  final UnderlineStyle underline;
  final bool strike;
  final bool doubleStrike;

  /// 0xAARRGGBB, or null for automatic (the reader's text colour).
  final int? color;

  /// Highlighter colour, 0xAARRGGBB.
  final int? highlight;

  /// Run shading, 0xAARRGGBB.
  final int? fill;
  final double size;

  /// Font family name as written in the document, or null for the default.
  final String? font;
  final VerticalTextPosition verticalPosition;
  final bool allCaps;
  final bool smallCaps;

  /// Extra space between characters, in points.
  final double letterSpacing;

  @override
  bool operator ==(Object other) =>
      other is RunFormat &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.doubleStrike == doubleStrike &&
      other.color == color &&
      other.highlight == highlight &&
      other.fill == fill &&
      other.size == size &&
      other.font == font &&
      other.verticalPosition == verticalPosition &&
      other.allCaps == allCaps &&
      other.smallCaps == smallCaps &&
      other.letterSpacing == letterSpacing;

  @override
  int get hashCode => Object.hash(bold, italic, underline, strike, doubleStrike, color, highlight, fill, size, font,
      verticalPosition, allCaps, smallCaps, letterSpacing);
}

/// A list item's number or bullet, already worked out (`1.`, `2.3`, `iv)`,
/// `•`), with its own formatting.
class ListMarker {
  const ListMarker(this.text, {this.format = RunFormat.plain, this.level = 0, this.suffix = ListMarkerSuffix.tab});

  final String text;
  final RunFormat format;

  /// 0-based list level.
  final int level;
  final ListMarkerSuffix suffix;
}

/// What separates a list marker from the text (`w:suff`).
enum ListMarkerSuffix { tab, space, nothing }
