import '../engines/word/word_model.dart';

/// Which part of the document a [WordItem] comes from.
enum WordItemKind {
  /// The first section's header.
  header,

  /// The main text.
  body,

  /// The last section's footer.
  footer,

  /// Footnotes and endnotes.
  notes,
}

/// One entry of the continuous view's scrolling list.
class WordItem {
  /// An item showing [block], from the part [kind] says.
  const WordItem(this.block, this.kind);

  /// The block shown.
  final WordBlock block;

  /// Which part of the document the block comes from.
  final WordItemKind kind;
}

/// A [WordDocument] laid out for the continuous view: one scrolling list
/// of blocks (the first section's header, the body, the last section's
/// footer, then footnotes and endnotes), and every paragraph - table cells
/// included - numbered in that reading order.
///
/// The paragraph numbers tie search, jumping and in-document links to what
/// is on screen.
class WordDocumentLayout {
  /// Lays out [document] and numbers its paragraphs.
  WordDocumentLayout(this.document) {
    final first = document.sections.first;
    final last = document.sections.last;
    final header =
        first.headers[first.titlePage ? HeaderFooterKind.first : HeaderFooterKind.defaultKind] ??
        first.headers[HeaderFooterKind.defaultKind];
    final footer = last.footers[HeaderFooterKind.defaultKind];
    for (final block in header ?? const <WordBlock>[]) {
      _add(block, WordItemKind.header);
    }
    for (final block in document.body) {
      _add(block, WordItemKind.body);
    }
    for (final block in footer ?? const <WordBlock>[]) {
      _add(block, WordItemKind.footer);
    }
    for (final note in [...document.footnotes.values, ...document.endnotes.values]) {
      for (final block in note) {
        _add(block, WordItemKind.notes);
      }
    }
  }

  /// The document laid out.
  final WordDocument document;

  /// The scrolling list's entries, in order.
  final items = <WordItem>[];

  /// Every paragraph, in reading order; a paragraph's number is its index.
  final paragraphs = <WordParagraph>[];

  /// For each paragraph number, the index of the item that shows it.
  final itemOfParagraph = <int>[];

  /// Bookmark name -> paragraph number.
  final bookmarks = <String, int>{};

  final _numbers = Map<WordParagraph, int>.identity();

  /// Index of the first footnote/endnote item, or null without notes.
  int? get firstNoteItem {
    final index = items.indexWhere((item) => item.kind == WordItemKind.notes);
    return index < 0 ? null : index;
  }

  /// [paragraph]'s number, or null if it isn't part of this layout.
  int? numberOf(WordParagraph paragraph) => _numbers[paragraph];

  void _add(WordBlock block, WordItemKind kind) {
    items.add(WordItem(block, kind));
    _number(block, items.length - 1);
  }

  void _number(WordBlock block, int item) {
    switch (block) {
      case WordParagraph():
        final number = paragraphs.length;
        paragraphs.add(block);
        itemOfParagraph.add(item);
        _numbers[block] = number;
        for (final inline in block.inlines) {
          if (inline is WordBookmark) bookmarks.putIfAbsent(inline.name, () => number);
        }
      case WordTable():
        for (final row in block.rows) {
          for (final cell in row.cells) {
            for (final inner in cell.blocks) {
              _number(inner, item);
            }
          }
        }
      case WordSectionBreak():
        break;
    }
  }
}
