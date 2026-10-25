import 'dart:typed_data';

/// A Word document as read from a `.docx`, ready to display: styles are
/// already resolved onto every paragraph and run, list markers are already
/// numbered, and field codes are reduced to their shown results.
///
/// Plain data all the way down, so a document parsed in a background
/// isolate can be sent back to the UI isolate.
class WordDocument {
  /// A document of [body] blocks laid out in [sections].
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

  /// Endnote text by note id, like [footnotes].
  final Map<String, List<WordBlock>> endnotes;

  /// Image bytes by package part name; [WordImage.part] points here.
  final Map<String, Uint8List> images;

  /// The theme's hyperlink colour (0xAARRGGBB), for links whose text has
  /// no colour of its own.
  final int linkColor;
}

/// A section's page and its headers/footers. Sizes are in points.
class WordSection {
  /// A section's page setup; the defaults are a US Letter page with 1-inch
  /// margins and no headers or footers.
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

  /// Page width (`w:pgSz`); swapped with [pageHeight] if needed so a
  /// landscape page is wider than it is tall.
  final double pageWidth;

  /// Page height (`w:pgSz`).
  final double pageHeight;

  /// Top margin (`w:pgMar`).
  final double marginTop;

  /// Bottom margin (`w:pgMar`).
  final double marginBottom;

  /// Left (start) margin (`w:pgMar`).
  final double marginLeft;

  /// Right (end) margin (`w:pgMar`).
  final double marginRight;

  /// Header text by kind (`w:headerReference`). A kind the section doesn't
  /// define is carried over from the previous section.
  final Map<HeaderFooterKind, List<WordBlock>> headers;

  /// Footer text by kind (`w:footerReference`), carried over like [headers].
  final Map<HeaderFooterKind, List<WordBlock>> footers;

  /// Whether the first page uses the [HeaderFooterKind.first] header/footer.
  final bool titlePage;
}

/// Which pages a header or footer is for (`w:headerReference w:type`).
enum HeaderFooterKind {
  /// Every page without a more specific one (`default`).
  defaultKind,

  /// The section's first page, when [WordSection.titlePage] is set.
  first,

  /// Even-numbered pages.
  even,
}

// --- Blocks ----------------------------------------------------------------

/// A block-level piece of content: a [WordParagraph], a [WordTable] or a
/// [WordSectionBreak].
sealed class WordBlock {
  /// Base constructor for subclasses.
  const WordBlock();
}

/// A paragraph (`w:p`): inline content with resolved formatting.
class WordParagraph extends WordBlock {
  /// A paragraph of [inlines], formatted by [format].
  const WordParagraph(this.inlines, {this.format = ParagraphFormat.plain, this.marker, this.outlineLevel});

  /// The paragraph's content, in order.
  final List<WordInline> inlines;

  /// The paragraph's formatting, with its style, list level and direct
  /// formatting already applied.
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

/// A table (`w:tbl`) of [rows] on a grid of [columnWidths].
class WordTable extends WordBlock {
  /// A table of [rows] on a grid of [columnWidths].
  const WordTable({required this.rows, this.columnWidths = const [], this.alignment = ParagraphAlignment.left});

  /// Widths of the table's grid columns in points (`w:tblGrid`); cells span
  /// one or more of these.
  final List<double> columnWidths;

  /// The table's rows, top to bottom.
  final List<WordTableRow> rows;

  /// Where the table sits between the margins (`w:tblPr/w:jc`): left,
  /// center or right; never [ParagraphAlignment.justify].
  final ParagraphAlignment alignment;
}

/// A table row (`w:tr`).
class WordTableRow {
  /// A row of [cells].
  const WordTableRow(this.cells, {this.isHeader = false, this.height});

  /// The row's cells, left to right, including [WordTableCell.covered]
  /// cells of vertical merges.
  final List<WordTableCell> cells;

  /// Repeats at the top of each page in a paged layout.
  final bool isHeader;

  /// Minimum height in points, or null for automatic.
  final double? height;
}

/// A table cell (`w:tc`).
class WordTableCell {
  /// A cell holding [blocks].
  const WordTableCell(
    this.blocks, {
    this.columnSpan = 1,
    this.rowSpan = 1,
    this.covered = false,
    this.fill,
    this.verticalAlignment = CellVerticalAlignment.top,
    this.borders = WordCellBorders.none,
  });

  /// The cell's content; empty for a [covered] cell.
  final List<WordBlock> blocks;

  /// Grid columns this cell spans (`w:gridSpan`).
  final int columnSpan;

  /// Rows this cell spans, from vertical merges (`w:vMerge`). The cells it
  /// covers in later rows are kept, [covered], so each row still accounts
  /// for every grid column.
  final int rowSpan;

  /// Whether this cell is covered by a vertically merged cell above it (a
  /// `w:vMerge` continuation); covered cells aren't drawn.
  final bool covered;

  /// Background as 0xAARRGGBB, or null.
  final int? fill;

  /// How the content sits vertically in the cell (`w:vAlign`).
  final CellVerticalAlignment verticalAlignment;

  /// The cell's borders: its own `w:tcBorders`, otherwise the table style's
  /// outer or inside borders for its position.
  final WordCellBorders borders;
}

/// How a table cell's content sits vertically (`w:vAlign`).
enum CellVerticalAlignment {
  /// At the top of the cell.
  top,

  /// Centred in the cell.
  center,

  /// At the bottom of the cell.
  bottom,
}

/// A line on one side of a cell or paragraph.
class WordBorderLine {
  /// A line [width] points wide in [color].
  const WordBorderLine({this.width = 0.5, this.color});

  /// In points.
  final double width;

  /// 0xAARRGGBB, or null for automatic (the text colour).
  final int? color;
}

/// The four borders of a table cell; a null side has no line.
class WordCellBorders {
  /// Borders with the given sides.
  const WordCellBorders({this.top, this.bottom, this.left, this.right});

  /// No borders at all.
  static const none = WordCellBorders();

  /// The top border, or null for none.
  final WordBorderLine? top;

  /// The bottom border, or null for none.
  final WordBorderLine? bottom;

  /// The left (start) border, or null for none.
  final WordBorderLine? left;

  /// The right (end) border, or null for none.
  final WordBorderLine? right;
}

/// Where one section ends and the next begins.
class WordSectionBreak extends WordBlock {
  /// A break ending section [sectionIndex].
  const WordSectionBreak(this.sectionIndex);

  /// Index into [WordDocument.sections] of the section that just ended.
  final int sectionIndex;
}

// --- Inline content ----------------------------------------------------------

/// A piece of a paragraph's content: text, a tab, a break, an image, a note
/// mark, a page field or a bookmark.
sealed class WordInline {
  /// Base constructor for subclasses.
  const WordInline();

  /// How this reads in [WordParagraph.plainText].
  String get plainText;
}

/// A stretch of text with one formatting (from a run, `w:r`).
class WordText extends WordInline {
  /// [text] formatted by [format], part of [link] if it isn't null.
  const WordText(this.text, {this.format = RunFormat.plain, this.link});

  /// The text as shown (field results included, field codes left out).
  final String text;

  /// The text's resolved formatting.
  final RunFormat format;

  /// The link this text belongs to, or null if it isn't linked.
  final WordLink? link;

  @override
  String get plainText => text;
}

/// A tab character (`w:tab`, `w:ptab`).
class WordTab extends WordInline {
  /// A tab in a run formatted by [format].
  const WordTab({this.format = RunFormat.plain});

  /// The formatting of the run the tab is in.
  final RunFormat format;

  @override
  String get plainText => '\t';
}

/// What a [WordBreak] ends (`w:br w:type`).
enum BreakKind {
  /// A line; the text continues on the next line.
  line,

  /// A page; the text continues on the next page.
  page,

  /// A column; the text continues in the next column.
  column,
}

/// A break inside a paragraph (`w:br`, `w:cr`).
class WordBreak extends WordInline {
  /// A break of [kind].
  const WordBreak(this.kind);

  /// What the break ends: a line, a page or a column (`w:br w:type`).
  final BreakKind kind;

  @override
  String get plainText => '\n';
}

/// A picture (DrawingML `w:drawing` or a VML picture).
class WordImage extends WordInline {
  /// An image stored as [part], shown at [width] by [height] points.
  const WordImage({
    required this.part,
    required this.width,
    required this.height,
    this.description,
    this.floating = false,
  });

  /// Key into [WordDocument.images].
  final String part;

  /// Display size in points.
  final double width;

  /// Display height in points.
  final double height;

  /// Alt text.
  final String? description;

  /// Anchored (floating) rather than inline; shown on a line of its own.
  final bool floating;

  @override
  String get plainText => '';
}

/// Whether a note is a footnote or an endnote.
enum NoteKind {
  /// A footnote, in [WordDocument.footnotes].
  footnote,

  /// An endnote, in [WordDocument.endnotes].
  endnote,
}

/// A footnote or endnote mark in the text (`w:footnoteReference`,
/// `w:endnoteReference`).
class WordNoteReference extends WordInline {
  /// A mark for note [id] of [kind], shown as [label].
  const WordNoteReference({required this.kind, required this.id, required this.label, this.format = RunFormat.plain});

  /// Whether the mark refers to a footnote or an endnote.
  final NoteKind kind;

  /// Key into [WordDocument.footnotes] / [WordDocument.endnotes].
  final String id;

  /// The mark shown: `1`, `2`... for footnotes, `i`, `ii`... for endnotes.
  final String label;

  /// The mark's resolved formatting.
  final RunFormat format;

  @override
  String get plainText => label;
}

/// What a [WordPageField] shows.
enum PageFieldKind {
  /// The number of the page it's on (`PAGE`).
  page,

  /// The number of pages in the document (`NUMPAGES`).
  pageCount,
}

/// A `PAGE` or `NUMPAGES` field: the page number (or count) where it's
/// shown. [fallback] is the result Word saved, for views without pages.
class WordPageField extends WordInline {
  /// A field of [kind], showing [fallback] where there are no pages.
  const WordPageField(this.kind, {this.fallback = '', this.format = RunFormat.plain});

  /// Whether the field shows the page number or the page count.
  final PageFieldKind kind;

  /// The result Word saved in the file; empty if there was none.
  final String fallback;

  /// The formatting the field result is shown in.
  final RunFormat format;

  @override
  String get plainText => fallback;
}

/// A named place a link can jump to (`w:bookmarkStart`).
class WordBookmark extends WordInline {
  /// A bookmark called [name].
  const WordBookmark(this.name);

  /// The bookmark's name (`w:name`), which [WordLink.anchor] refers to.
  final String name;

  @override
  String get plainText => '';
}

/// A link's target: a web address, or a bookmark in this document.
class WordLink {
  /// A link to [url] or to the bookmark [anchor].
  const WordLink({this.url, this.anchor});

  /// The web address (an external relationship target or a `HYPERLINK`
  /// field's address), or null for a link within the document.
  final String? url;

  /// The bookmark name to jump to (`w:anchor`, or a `HYPERLINK` field's
  /// `\l` switch), or null.
  final String? anchor;

  @override
  bool operator ==(Object other) => other is WordLink && other.url == url && other.anchor == anchor;

  @override
  int get hashCode => Object.hash(url, anchor);
}

// --- Formatting --------------------------------------------------------------

/// Horizontal alignment of a paragraph's lines (`w:jc`) or of a table.
enum ParagraphAlignment {
  /// Against the start (left) edge; also Word's default.
  left,

  /// Centred.
  center,

  /// Against the end (right) edge (`right` or `end`).
  right,

  /// Stretched to both edges (`both`, `distribute` and the kashida
  /// values).
  justify,
}

/// How [ParagraphFormat.lineSpacing] is measured (`w:spacing w:lineRule`).
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
  /// Paragraph formatting; the defaults are plain left-aligned single
  /// spacing with no indents or space around.
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

  /// The default formatting.
  static const plain = ParagraphFormat();

  /// Horizontal alignment of the lines (`w:jc`).
  final ParagraphAlignment alignment;

  /// Left (start) indent (`w:ind`).
  final double indentLeft;

  /// Right (end) indent (`w:ind`).
  final double indentRight;

  /// Positive for a first-line indent, negative for a hanging indent.
  final double firstLineIndent;

  /// Space above the paragraph (`w:spacing w:before`).
  final double spaceBefore;

  /// Space below the paragraph (`w:spacing w:after`).
  final double spaceAfter;

  /// Line spacing (`w:spacing w:line`): a multiple of single spacing for
  /// [LineSpacingRule.auto], otherwise a height in points.
  final double lineSpacing;

  /// How to read [lineSpacing] (`w:spacing w:lineRule`).
  final LineSpacingRule lineSpacingRule;

  /// Background as 0xAARRGGBB, or null.
  final int? fill;

  /// The line above the paragraph (`w:pBdr`), or null for none.
  final WordBorderLine? borderTop;

  /// The line below the paragraph (`w:pBdr`), or null for none.
  final WordBorderLine? borderBottom;

  /// The line on the left (start) side (`w:pBdr`), or null for none.
  final WordBorderLine? borderLeft;

  /// The line on the right (end) side (`w:pBdr`), or null for none.
  final WordBorderLine? borderRight;

  /// Whether the paragraph starts on a new page (`w:pageBreakBefore`).
  final bool pageBreakBefore;

  /// Whether the paragraph should stay on the same page as the next one
  /// (`w:keepNext`).
  final bool keepWithNext;

  /// Whether the paragraph runs right to left (`w:bidi`).
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

/// A run's underline (`w:u`). Word's many styles are reduced to these.
enum UnderlineStyle {
  /// No underline.
  none,

  /// One solid line; also used for styles not listed here (thick, words).
  single,

  /// Two lines.
  double,

  /// A dotted line.
  dotted,

  /// A dashed line, including dot-dash styles.
  dashed,

  /// A wavy line.
  wavy,
}

/// A run's position relative to the baseline (`w:vertAlign`).
enum VerticalTextPosition {
  /// On the baseline.
  baseline,

  /// Raised above the baseline.
  superscript,

  /// Lowered below the baseline.
  subscript,
}

/// A run's resolved formatting. Sizes in points.
class RunFormat {
  /// Run formatting; the defaults are plain 11-point text.
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

  /// The default formatting.
  static const plain = RunFormat();

  /// Whether the text is bold (`w:b`).
  final bool bold;

  /// Whether the text is italic (`w:i`).
  final bool italic;

  /// The underline (`w:u`).
  final UnderlineStyle underline;

  /// Whether the text is struck through with one line (`w:strike`).
  final bool strike;

  /// Whether the text is struck through with two lines (`w:dstrike`).
  final bool doubleStrike;

  /// 0xAARRGGBB, or null for automatic (the reader's text colour).
  final int? color;

  /// Highlighter colour, 0xAARRGGBB.
  final int? highlight;

  /// Run shading, 0xAARRGGBB.
  final int? fill;

  /// Font size in points (`w:sz`, which is in half-points).
  final double size;

  /// Font family name as written in the document, or null for the default.
  final String? font;

  /// Superscript, subscript or neither (`w:vertAlign`).
  final VerticalTextPosition verticalPosition;

  /// Whether lowercase letters show as capitals (`w:caps`).
  final bool allCaps;

  /// Whether lowercase letters show as small capitals (`w:smallCaps`).
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
  int get hashCode => Object.hash(
    bold,
    italic,
    underline,
    strike,
    doubleStrike,
    color,
    highlight,
    fill,
    size,
    font,
    verticalPosition,
    allCaps,
    smallCaps,
    letterSpacing,
  );
}

/// A list item's number or bullet, already worked out (`1.`, `2.3`, `iv)`,
/// `•`), with its own formatting.
class ListMarker {
  /// A marker showing [text], formatted by [format].
  const ListMarker(this.text, {this.format = RunFormat.plain, this.level = 0, this.suffix = ListMarkerSuffix.tab});

  /// The marker as shown, e.g. `1.` or `•`.
  final String text;

  /// The marker's formatting: the paragraph's run formatting with the list
  /// level's own on top.
  final RunFormat format;

  /// 0-based list level.
  final int level;

  /// What follows the marker before the text.
  final ListMarkerSuffix suffix;
}

/// What separates a list marker from the text (`w:suff`).
enum ListMarkerSuffix {
  /// A tab: the marker hangs in its own column before the text.
  tab,

  /// A single space.
  space,

  /// Nothing; the text follows the marker directly.
  nothing,
}
