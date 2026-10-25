import 'package:flutter/material.dart';

import '../common/document_viewer_strings.dart';
import '../common/document_viewer_theme.dart';
import '../engines/slides/pptx_parser.dart';
import 'slides_controller.dart';

/// Shows a [SlidesController]'s presentation one slide at a time: swipe,
/// or drive it from the controller.
///
/// Each slide shows its title, paragraphs (with bullet indent), tables and
/// pictures. It's a reading view rather than the original layout: the text
/// is drawn at [SlidesController.zoom] and reflows to fit. Search matches
/// are highlighted, the current one apart from the rest.
class SlidesView extends StatelessWidget {
  /// Shows [controller]'s slides.
  const SlidesView({super.key, required this.controller});

  /// The presentation to show.
  final SlidesController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final media = MediaQuery.of(context);
        final zoom = controller.zoom;
        final current = controller.currentSlideMatch;
        return MediaQuery(
          data: zoom == 1 ? media : media.copyWith(textScaler: TextScaler.linear(media.textScaler.scale(zoom))),
          child: PageView.builder(
            controller: controller.pageController,
            itemCount: controller.slides.length,
            onPageChanged: controller.onSlideChanged,
            itemBuilder: (context, index) => SlideCard(
              slide: controller.slides[index],
              number: index + 1,
              highlight: controller.searchQuery,
              currentOccurrence: current?.slide == index ? current!.occurrence : null,
            ),
          ),
        );
      },
    );
  }
}

/// One slide's content as a card: what [SlidesView] shows for each slide,
/// and usable on its own, for example scaled down as a preview.
class SlideCard extends StatelessWidget {
  /// Shows [slide], which is slide [number] (from 1).
  const SlideCard({super.key, required this.slide, required this.number, this.highlight = '', this.currentOccurrence});

  /// The slide to show.
  final PptxSlide slide;

  /// The slide's number, from 1, for the message on a slide with nothing to
  /// show.
  final int number;

  /// Text to highlight wherever it occurs (ignoring case); none when empty.
  final String highlight;

  /// Which occurrence of [highlight] on this slide (from 0, in reading
  /// order) is the search's current match; null when none is.
  final int? currentOccurrence;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = slide.title;
    final marker = _Highlighter(highlight, currentOccurrence, DocumentViewerTheme.of(context));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) ...[
                marker.text(title, text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
              ],
              for (final block in slide.blocks)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: _block(context, block, marker)),
              if (title == null && slide.blocks.isEmpty)
                Text(
                  DocumentViewerStrings.of(context).emptySlide(number),
                  style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static int _columnCount(List<List<String>> rows) =>
      rows.fold(0, (most, row) => row.length > most ? row.length : most);

  Widget _block(BuildContext context, PptxBlock block, _Highlighter marker) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return switch (block) {
      PptxParagraph(text: final paragraph, :final level) => Padding(
        padding: EdgeInsets.only(left: 18.0 * level),
        child: marker.text(paragraph, text.bodyLarge),
      ),
      PptxTable(:final rows) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: colors.outlineVariant),
          children: [
            for (final row in rows)
              TableRow(
                children: [
                  for (final cell in row)
                    Padding(padding: const EdgeInsets.all(8), child: marker.text(cell, text.bodyMedium)),
                  // Merged cells leave rows short; Table needs them even.
                  for (var i = row.length; i < _columnCount(rows); i++) const SizedBox.shrink(),
                ],
              ),
          ],
        ),
      ),
      PptxImage(:final bytes) => Center(
        child: Image.memory(bytes, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
      ),
    };
  }
}

/// Marks a search's occurrences in a slide's text, counting them in the
/// order the card draws its text, so the current one can stand out.
class _Highlighter {
  _Highlighter(String query, this._current, DocumentViewerTheme theme)
    : _needle = query.toLowerCase(),
      _match = theme.matchStyle(current: false),
      _currentMatch = theme.matchStyle(current: true);

  final String _needle;
  final int? _current;
  final TextStyle _match;
  final TextStyle _currentMatch;

  /// Occurrences drawn so far on this slide.
  int _seen = 0;

  Widget text(String text, TextStyle? style) {
    if (_needle.isEmpty) return Text(text, style: style);
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    for (var i = lower.indexOf(_needle); i != -1; i = lower.indexOf(_needle, start)) {
      if (i > start) spans.add(TextSpan(text: text.substring(start, i)));
      final style = _seen == _current ? _currentMatch : _match;
      spans.add(TextSpan(text: text.substring(i, i + _needle.length), style: style));
      _seen++;
      start = i + _needle.length;
    }
    spans.add(TextSpan(text: text.substring(start)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
