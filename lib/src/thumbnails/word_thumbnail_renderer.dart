import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../common/reader_contract.dart';
import '../engines/word/docx_reader.dart';
import '../engines/word/word_model.dart';
import '../word/word_document_layout.dart';
import '../word/word_document_view.dart';
import '../word/word_pagination.dart';
import '../word/word_paragraph_styler.dart';
import '../word/word_search_controller.dart';
import '../word/word_widgets.dart';
import 'offscreen_render.dart';
import 'thumbnail_renderer.dart';
import 'thumbnail_sources.dart';

/// A page of a `.docx` as the print layout shows it: paginated by
/// [WordPaginator] and drawn by the same [WordPageView] - header, footer,
/// margins and the section's page size included. Page 1, or with a saved
/// `paragraph`, the page that paragraph starts on.
class WordThumbnailRenderer implements ThumbnailRenderer {
  const WordThumbnailRenderer();

  /// Body blocks kept past the page wanted: far more than a page holds, so
  /// a long document isn't paginated (or sent over from the parsing
  /// isolate) in full.
  static const int _maxBlocks = 150;

  /// Body blocks paginated ahead of the wanted paragraph, at most. Past
  /// this, the thumbnail is a page that starts with the paragraph's block
  /// rather than the real page holding it.
  static const int _maxBlocksBefore = 1000;

  @override
  Future<ui.Image?> render(String path, {required int width, ReadingPosition? position}) async {
    final wanted = positionIndex(position, PositionKeys.paragraph);
    final result = await parseOfficeFile(path, (bytes) => _blocksFor(bytes, wanted));
    if (result == null) return null;
    final (document, paragraph) = result;
    final layout = WordDocumentLayout(document);
    final styler = WordParagraphStyler(
      scheme: WordPageView.paper.colorScheme,
      linkColor: document.linkColor,
      pageNumber: 1,
      pageCount: 1,
    );
    final pagination = WordPaginator(layout, WordMeasurer(styler)).paginate();
    final pages = pagination.pages;
    final index = paragraph == null ? 0 : (pagination.pageOfParagraph[paragraph] ?? 0);
    final page = pages[index];
    final search = WordSearchController();
    try {
      return await renderOffscreen(
        WordScope(
          layout: layout,
          search: search,
          onLink: (_) {},
          onNote: (_) {},
          anchors: <int, BuildContext>{},
          child: WordPageInfo(
            number: index + 1,
            count: pages.length,
            // A page whose content can't be split grows past its size;
            // the thumbnail shows its top.
            child: OverflowBox(alignment: Alignment.topCenter, maxHeight: double.infinity, child: WordPageView(page)),
          ),
        ),
        size: Size(page.width, page.height),
        width: width,
        theme: WordPageView.paper,
      );
    } finally {
      search.dispose();
    }
  }

  /// The document cut to the blocks the wanted page needs, and the wanted
  /// paragraph's number in the cut document (null for page 1). [wanted]
  /// numbers paragraphs as the reader's [WordDocumentLayout] does; one
  /// that isn't in the body (a header's, a note's) or doesn't exist means
  /// page 1. Notes, which start on a page after the body, are left out of a
  /// cut document.
  static (WordDocument, int?) _blocksFor(Uint8List bytes, int? wanted) {
    final document = DocxReader.read(bytes);
    final body = document.body;
    final full = WordDocumentLayout(document);
    final headerItems = full.items.takeWhile((item) => item.kind == WordItemKind.header).length;
    var block = 0;
    WordParagraph? target;
    if (wanted != null && wanted < full.paragraphs.length) {
      final item = full.itemOfParagraph[wanted];
      if (full.items[item].kind == WordItemKind.body) {
        block = item - headerItems;
        target = full.paragraphs[wanted];
      }
    }

    final WordDocument cut;
    if (block <= _maxBlocksBefore) {
      final keep = block + _maxBlocks;
      if (body.length <= keep && document.footnotes.isEmpty && document.endnotes.isEmpty) {
        cut = document;
      } else {
        cut = WordDocument(
          body: body.take(keep).toList(),
          sections: document.sections,
          images: document.images,
          linkColor: document.linkColor,
        );
      }
    } else {
      // Paginate from the paragraph's block, in the section it's in.
      final section = switch (body.take(block).whereType<WordSectionBreak>().lastOrNull) {
        final WordSectionBreak previous => (previous.sectionIndex + 1).clamp(0, document.sections.length - 1),
        null => 0,
      };
      cut = WordDocument(
        body: [
          for (final kept in body.skip(block).take(_maxBlocks))
            if (kept is WordSectionBreak) WordSectionBreak(kept.sectionIndex - section) else kept,
        ],
        sections: document.sections.sublist(section),
        images: document.images,
        linkColor: document.linkColor,
      );
    }
    return (cut, target == null ? null : WordDocumentLayout(cut).numberOf(target));
  }
}
