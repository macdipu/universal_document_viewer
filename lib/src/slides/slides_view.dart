import 'package:flutter/material.dart';

import 'pptx_parser.dart';
import 'slides_controller.dart';

/// One slide at a time, swiped or driven by [SlidesController]. Shows
/// each slide's title, paragraphs (with bullet indent), tables and
/// pictures; it's a reading view, not the original layout. The text is
/// drawn at [SlidesController.zoom] and reflows; text matching the
/// search query is highlighted.
class SlidesView extends StatelessWidget {
  const SlidesView({super.key, required this.controller});

  final SlidesController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final media = MediaQuery.of(context);
        final zoom = controller.zoom;
        return MediaQuery(
          data: zoom == 1 ? media : media.copyWith(textScaler: TextScaler.linear(media.textScaler.scale(zoom))),
          child: PageView.builder(
            controller: controller.pageController,
            itemCount: controller.slides.length,
            onPageChanged: controller.onSlideChanged,
            itemBuilder: (context, index) =>
                SlideCard(slide: controller.slides[index], number: index + 1, highlight: controller.searchQuery.trim()),
          ),
        );
      },
    );
  }
}

/// A single slide's content as a card.
class SlideCard extends StatelessWidget {
  const SlideCard({super.key, required this.slide, required this.number, this.highlight = ''});

  final PptxSlide slide;

  /// 1-based, for the "no content" message.
  final int number;

  /// Text to highlight (any case), from a search; none when empty.
  final String highlight;

  /// [text] with each occurrence of [highlight] marked.
  Widget _text(BuildContext context, String text, TextStyle? style) {
    if (highlight.isEmpty) return Text(text, style: style);
    final colors = Theme.of(context).colorScheme;
    final mark = TextStyle(backgroundColor: colors.secondaryContainer, color: colors.onSecondaryContainer);
    final lower = text.toLowerCase();
    final needle = highlight.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    for (var i = lower.indexOf(needle); i != -1; i = lower.indexOf(needle, start)) {
      if (i > start) spans.add(TextSpan(text: text.substring(start, i)));
      spans.add(TextSpan(text: text.substring(i, i + needle.length), style: mark));
      start = i + needle.length;
    }
    spans.add(TextSpan(text: text.substring(start)));
    return Text.rich(TextSpan(style: style, children: spans));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = slide.title;
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
                _text(context, title, text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
              ],
              for (final block in slide.blocks)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: _block(context, block)),
              if (title == null && slide.blocks.isEmpty)
                Text(
                  'Slide $number has no text or pictures to show.',
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

  Widget _block(BuildContext context, PptxBlock block) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return switch (block) {
      PptxParagraph(:final text, :final level) => Padding(
        padding: EdgeInsets.only(left: 18.0 * level),
        child: _text(context, text, Theme.of(context).textTheme.bodyLarge),
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
                    Padding(padding: const EdgeInsets.all(8), child: _text(context, cell, text.bodyMedium)),
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

/// "n / N" with previous/next buttons, for under a [SlidesView].
class SlideNavigationBar extends StatelessWidget {
  const SlideNavigationBar({super.key, required this.controller});

  final SlidesController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        color: colors.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: 'Previous slide',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: controller.canGoPrevious ? controller.previousSlide : null,
              ),
              Text(
                '${controller.currentSlide + 1} / ${controller.slides.length}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              IconButton(
                tooltip: 'Next slide',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: controller.canGoNext ? controller.nextSlide : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
