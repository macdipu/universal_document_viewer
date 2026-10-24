import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engines/word/word_model.dart';
import 'word_document_layout.dart';
import 'word_paragraph_styler.dart';
import 'word_widgets.dart';

/// One block on a page. A paragraph split across pages appears as pieces:
/// [number] is the whole paragraph's number and [textOffset] where the
/// piece starts in its text.
class WordPageEntry {
  const WordPageEntry(this.block, {this.number, this.textOffset = 0});

  final WordBlock block;
  final int? number;
  final int textOffset;
}

class WordPage {
  WordPage({required this.section, required this.sectionIndex, required this.firstOfSection});

  final WordSection section;
  final int sectionIndex;

  /// The first page of its section, which may have its own header/footer.
  final bool firstOfSection;
  final entries = <WordPageEntry>[];

  /// Logical-pixel page size.
  double get width => section.pageWidth * wordScale;
  double get height => section.pageHeight * wordScale;
  double get bodyWidth => math.max(1, (section.pageWidth - section.marginLeft - section.marginRight) * wordScale);
  double get bodyHeight => math.max(1, (section.pageHeight - section.marginTop - section.marginBottom) * wordScale);

  /// The header/footer for this page (first-page ones when the section
  /// asks for them).
  List<WordBlock>? get header => _pick(section.headers);
  List<WordBlock>? get footer => _pick(section.footers);

  List<WordBlock>? _pick(Map<HeaderFooterKind, List<WordBlock>> parts) =>
      firstOfSection && section.titlePage ? parts[HeaderFooterKind.first] : parts[HeaderFooterKind.defaultKind];
}

/// A document split into pages, and which page each paragraph starts on.
class WordPagination {
  const WordPagination(this.pages, this.pageOfParagraph);

  final List<WordPage> pages;
  final Map<int, int> pageOfParagraph;
}

/// Measures blocks exactly as the widgets lay them out: paragraphs through
/// [TextPainter] with the spans [WordParagraphStyler] builds for the view.
class WordMeasurer {
  WordMeasurer(this.styler, {this.textScaler = TextScaler.noScaling});

  final WordParagraphStyler styler;
  final TextScaler textScaler;

  double blockHeight(WordBlock block, double width) => switch (block) {
    final WordParagraph paragraph => paragraphHeight(paragraph, width),
    final WordTable table => tableHeight(table, width),
    WordSectionBreak() => 0,
  };

  double paragraphHeight(WordParagraph paragraph, double width, {int textOffset = 0}) {
    final geometry = ParagraphGeometry(paragraph, width);
    final (painter, _) = _paint(paragraph, geometry, textOffset);
    final height = math.max(painter.height, _markerHeight(paragraph));
    painter.dispose();
    return height + geometry.chrome;
  }

  /// Splits [paragraph] so its first piece fits in [available] height;
  /// null when not even its first line fits.
  (WordParagraph head, WordParagraph tail, int tailOffset)? splitParagraph(
    WordParagraph paragraph,
    double width,
    double available, {
    int textOffset = 0,
  }) {
    final geometry = ParagraphGeometry(paragraph, width);
    final (painter, spans) = _paint(paragraph, geometry, textOffset);
    try {
      final lines = painter.computeLineMetrics();
      var budget = available - geometry.spaceBefore - geometry.boxVertical;
      var fitting = 0;
      var bottom = 0.0;
      for (final line in lines) {
        if (line.height > budget) break;
        budget -= line.height;
        bottom += line.height;
        fitting++;
      }
      if (fitting == 0 || fitting >= lines.length) return null;
      final last = lines[fitting - 1];
      final probe = painter.getPositionForOffset(Offset(geometry.textWidth - 1, bottom - last.height / 2));
      final laidOutEnd = painter.getLineBoundary(probe).end;
      final cut = spans.plainOffsetOf(laidOutEnd) - textOffset;
      if (cut <= 0 || cut >= paragraph.plainText.length) return null;
      final (headInlines, tailInlines) = _splitInlines(paragraph.inlines, cut);
      final head = WordParagraph(
        headInlines,
        format: paragraph.format.withSpacing(after: 0),
        marker: paragraph.marker,
        outlineLevel: paragraph.outlineLevel,
      );
      final tail = WordParagraph(tailInlines, format: paragraph.format.withSpacing(before: 0));
      return (head, tail, textOffset + cut);
    } finally {
      painter.dispose();
    }
  }

  double tableHeight(WordTable table, double width) {
    final widths = WordTableView.columnWidthsFor(table, width);
    var height = 2 * WordTableView.tableMarginY;
    for (var r = 0; r < table.rows.length; r++) {
      height += rowHeight(table, r, widths);
    }
    return height;
  }

  /// A row's height: its tallest single-row cell, or its minimum height.
  double rowHeight(WordTable table, int row, List<double> widths) {
    final tableRow = table.rows[row];
    var height = (tableRow.height ?? 0) * wordScale;
    var column = 0;
    for (final cell in tableRow.cells) {
      if (!cell.covered && cell.rowSpan == 1) {
        var cellWidth = 0.0;
        for (var c = column; c < column + cell.columnSpan && c < widths.length; c++) {
          cellWidth += widths[c];
        }
        final inner = math.max(1.0, cellWidth - 2 * WordTableView.cellPaddingX - 1);
        var content = 2 * WordTableView.cellPaddingY + 1;
        for (final block in cell.blocks) {
          content += blockHeight(block, inner);
        }
        height = math.max(height, content);
      }
      column += cell.columnSpan;
    }
    return height;
  }

  (TextPainter, ParagraphSpans) _paint(WordParagraph paragraph, ParagraphGeometry geometry, int textOffset) {
    final spans = styler.spans(paragraph, textOffset: textOffset, imageWidth: geometry.textWidth);
    final painter =
        TextPainter(
            text: spans.root,
            textAlign: WordParagraphStyler.textAlignOf(paragraph.format),
            textDirection: paragraph.format.rightToLeft ? TextDirection.rtl : TextDirection.ltr,
            textScaler: textScaler,
          )
          ..setPlaceholderDimensions(spans.placeholders)
          ..layout(maxWidth: geometry.textWidth);
    return (painter, spans);
  }

  double _markerHeight(WordParagraph paragraph) {
    final marker = paragraph.marker;
    if (marker == null || !WordParagraphStyler.markerInColumn(paragraph)) return 0;
    final style = styler
        .textStyle(marker.format, null, link: false)
        .copyWith(
          height: WordParagraphStyler.lineHeightOf(paragraph.format, WordParagraphStyler.firstSizeOf(paragraph)),
        );
    final painter = TextPainter(
      text: TextSpan(text: marker.text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// Inline content before and after plain-text offset [cut]. Text is cut
  /// mid-run; an image or note mark goes wholly to the side it starts on.
  static (List<WordInline>, List<WordInline>) _splitInlines(List<WordInline> inlines, int cut) {
    final head = <WordInline>[];
    final tail = <WordInline>[];
    var offset = 0;
    for (final inline in inlines) {
      final length = inline.plainText.length;
      if (offset + length <= cut && !(length == 0 && offset == cut && head.isNotEmpty)) {
        head.add(inline);
      } else if (offset >= cut) {
        tail.add(inline);
      } else if (inline is WordText) {
        final at = cut - offset;
        head.add(WordText(inline.text.substring(0, at), format: inline.format, link: inline.link));
        tail.add(WordText(inline.text.substring(at), format: inline.format, link: inline.link));
      } else {
        head.add(inline);
      }
      offset += length;
    }
    return (head, tail);
  }
}

/// Splits a document's body (then its notes) into pages.
class WordPaginator {
  WordPaginator(this.layout, this.measurer);

  final WordDocumentLayout layout;
  final WordMeasurer measurer;

  final _pages = <WordPage>[];
  final _pageOfParagraph = <int, int>{};
  late WordPage _page;
  var _used = 0.0;

  WordPagination paginate() {
    final sections = layout.document.sections;
    _startPage(sections.first, 0, firstOfSection: true);
    var section = 0;
    for (final block in layout.document.body) {
      switch (block) {
        case WordSectionBreak(:final sectionIndex):
          section = math.min(sectionIndex + 1, sections.length - 1);
          _startPage(sections[section], section, firstOfSection: true);
        case WordParagraph():
          _placeParagraph(block);
        case WordTable():
          _placeTable(block);
      }
    }
    final notes = [...layout.document.footnotes.values, ...layout.document.endnotes.values];
    if (notes.isNotEmpty) {
      _startPage(sections.last, sections.length - 1, firstOfSection: false);
      for (final note in notes) {
        for (final block in note) {
          if (block is WordParagraph) {
            _placeParagraph(block);
          } else if (block is WordTable) {
            _placeTable(block);
          }
        }
      }
    }
    // A section break at the very end leaves an empty last page.
    if (_pages.length > 1 && _pages.last.entries.isEmpty) _pages.removeLast();
    return WordPagination(List.unmodifiable(_pages), _pageOfParagraph);
  }

  void _startPage(WordSection section, int index, {required bool firstOfSection}) {
    // Reuse a still-empty page (e.g. a break right after another).
    if (_pages.isNotEmpty && _pages.last.entries.isEmpty && _pages.last.sectionIndex == index) return;
    _page = WordPage(section: section, sectionIndex: index, firstOfSection: firstOfSection);
    _pages.add(_page);
    _used = 0;
  }

  void _newPage() => _startPage(_page.section, _page.sectionIndex, firstOfSection: false);

  void _add(WordPageEntry entry, double height) {
    _page.entries.add(entry);
    _used += height;
    if (entry.number case final number? when entry.textOffset == 0) {
      _pageOfParagraph.putIfAbsent(number, () => _pages.length - 1);
    }
  }

  void _placeParagraph(WordParagraph paragraph) {
    final number = layout.numberOf(paragraph);
    if (paragraph.format.pageBreakBefore && _page.entries.isNotEmpty) _newPage();
    // An explicit page break ends the page after the text before it.
    final parts = _splitAtPageBreaks(paragraph);
    var offset = 0;
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) _newPage();
      _flow(parts[i], number, offset);
      offset += parts[i].plainText.length + 1;
    }
  }

  /// Places a paragraph (or piece), splitting it between lines where it
  /// meets the bottom of the page. Never clips: a piece that can't be split
  /// goes on a page of its own, which grows if it must.
  void _flow(WordParagraph paragraph, int? number, int textOffset) {
    var piece = paragraph;
    var offset = textOffset;
    for (var guard = 0; guard < 10000; guard++) {
      final height = measurer.paragraphHeight(piece, _page.bodyWidth, textOffset: offset);
      final room = _page.bodyHeight - _used;
      if (height <= room || (_page.entries.isEmpty && height <= room + 0.5)) {
        _add(WordPageEntry(piece, number: number, textOffset: offset), height);
        return;
      }
      final split = measurer.splitParagraph(piece, _page.bodyWidth, room, textOffset: offset);
      if (split == null) {
        if (_page.entries.isEmpty) {
          _add(WordPageEntry(piece, number: number, textOffset: offset), height);
          return;
        }
        _newPage();
        continue;
      }
      final (head, tail, tailOffset) = split;
      _add(
        WordPageEntry(head, number: number, textOffset: offset),
        measurer.paragraphHeight(head, _page.bodyWidth, textOffset: offset),
      );
      _newPage();
      piece = tail;
      offset = tailOffset;
    }
  }

  /// Splits a table between rows, repeating its header rows on each page.
  void _placeTable(WordTable table) {
    final widths = WordTableView.columnWidthsFor(table, _page.bodyWidth);
    final heights = [for (var r = 0; r < table.rows.length; r++) measurer.rowHeight(table, r, widths)];
    final headerCount = table.rows.takeWhile((row) => row.isHeader).length;
    final headerHeight = heights.take(headerCount).fold(0.0, (a, b) => a + b);
    var rows = <WordTableRow>[];
    var rowsHeight = 0.0;

    void flush() {
      if (rows.isEmpty) return;
      final fragment = WordTable(rows: rows, columnWidths: table.columnWidths, alignment: table.alignment);
      _add(WordPageEntry(fragment), rowsHeight + 2 * WordTableView.tableMarginY);
      for (final row in rows) {
        for (final cell in row.cells) {
          for (final block in cell.blocks) {
            _markParagraphs(block);
          }
        }
      }
      rows = [];
      rowsHeight = 0;
    }

    for (var r = 0; r < table.rows.length; r++) {
      final room = _page.bodyHeight - _used - 2 * WordTableView.tableMarginY;
      if (rows.isNotEmpty && rowsHeight + heights[r] > room) {
        flush();
        _newPage();
        if (r >= headerCount && headerCount > 0) {
          rows.addAll(table.rows.take(headerCount));
          rowsHeight += headerHeight;
        }
      } else if (rows.isEmpty && heights[r] > room && _page.entries.isNotEmpty) {
        _newPage();
      }
      rows.add(table.rows[r]);
      rowsHeight += heights[r];
    }
    flush();
  }

  void _markParagraphs(WordBlock block) {
    switch (block) {
      case WordParagraph():
        if (layout.numberOf(block) case final number?) _pageOfParagraph.putIfAbsent(number, () => _pages.length - 1);
      case WordTable():
        for (final row in block.rows) {
          for (final cell in row.cells) {
            cell.blocks.forEach(_markParagraphs);
          }
        }
      case WordSectionBreak():
        break;
    }
  }

  /// The paragraph cut at its page breaks (`w:br w:type="page"`), breaks
  /// dropped. A piece may be empty: like Word, a break at the end leaves
  /// the paragraph mark's line at the top of the next page. Most
  /// paragraphs have no breaks and come back whole.
  static List<WordParagraph> _splitAtPageBreaks(WordParagraph paragraph) {
    if (!paragraph.inlines.any((i) => i is WordBreak && i.kind == BreakKind.page)) return [paragraph];
    final parts = <List<WordInline>>[[]];
    for (final inline in paragraph.inlines) {
      if (inline is WordBreak && inline.kind == BreakKind.page) {
        parts.add([]);
      } else {
        parts.last.add(inline);
      }
    }
    return [
      for (var i = 0; i < parts.length; i++)
        WordParagraph(
          parts[i],
          format: i == 0 ? paragraph.format : paragraph.format.withSpacing(before: 0),
          marker: i == 0 ? paragraph.marker : null,
          outlineLevel: i == 0 ? paragraph.outlineLevel : null,
        ),
    ];
  }
}
