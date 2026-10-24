import 'package:flutter/material.dart';

import 'pptx_parser.dart';
import 'slide_deck_controller.dart';

/// One slide at a time, swiped or driven by [SlideDeckController]. Shows
/// each slide's title, paragraphs (with bullet indent), tables and
/// pictures; it's a reading view, not the original layout.
class SlideDeckView extends StatelessWidget {
  const SlideDeckView({super.key, required this.controller});

  final SlideDeckController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PageView.builder(
        controller: controller.pageController,
        itemCount: controller.slides.length,
        onPageChanged: controller.onSlideChanged,
        itemBuilder: (context, index) => SlideCard(slide: controller.slides[index], number: index + 1),
      ),
    );
  }
}

/// A single slide's content as a card.
class SlideCard extends StatelessWidget {
  const SlideCard({super.key, required this.slide, required this.number});

  final PptxSlide slide;

  /// 1-based, for the "no content" message.
  final int number;

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
                Text(title, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
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
        child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
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
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(cell, style: text.bodyMedium),
                    ),
                  // Merged cells leave rows short; Table needs them even.
                  for (var i = row.length; i < _columnCount(rows); i++) const SizedBox.shrink(),
                ],
              ),
          ],
        ),
      ),
      PptxImage(:final bytes) => Center(
        child: Image.memory(bytes, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
      ),
    };
  }
}

/// "n / N" with previous/next buttons, for under a [SlideDeckView].
class SlideNavigationBar extends StatelessWidget {
  const SlideNavigationBar({super.key, required this.controller});

  final SlideDeckController controller;

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
