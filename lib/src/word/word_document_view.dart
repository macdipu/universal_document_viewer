import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:url_launcher/url_launcher.dart';

import '../engines/word/word_model.dart';
import 'word_document_controller.dart';
import 'word_document_layout.dart';
import 'word_pagination.dart';
import 'word_paragraph_styler.dart';
import 'word_widgets.dart';

/// A `.docx`, lazily built, in one of two layouts
/// ([WordDocumentController.viewMode]):
///
/// - **continuous**: the text reflowed to the screen - the first section's
///   header, the body, the last section's footer, then the notes;
/// - **paged**: Word's print layout - pages at their real size (scaled to
///   fit), split by measuring the text exactly as drawn, each with its
///   section's header and footer and live page numbers.
///
/// Search highlights and jumping come from
/// [WordDocumentController.searchController]. Tapping a note mark shows the
/// note; links open (web links outside the app, `http`/`https`/`mailto`
/// only) or jump to their bookmark.
class WordDocumentView extends StatefulWidget {
  const WordDocumentView({super.key, required this.controller, this.padding = const EdgeInsets.all(16)});

  final WordDocumentController controller;
  final EdgeInsetsGeometry padding;

  @override
  State<WordDocumentView> createState() => _WordDocumentViewState();
}

class _WordDocumentViewState extends State<WordDocumentView> {
  final _anchors = <int, BuildContext>{};

  /// Measured heights of the list items built so far, for estimating where
  /// an unbuilt item is. Cleared when the layout changes.
  final _itemHeights = <int, double>{};
  int? _lastMatchKey;
  bool _restored = false;

  /// The paragraph at the top when scrolling last settled; see
  /// [_reportTopParagraph].
  int? _readingParagraph;
  late WordViewMode _mode;

  WordPagination? _pagination;
  Object? _paginationKey;

  WordDocumentController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _mode = controller.viewMode;
    controller.addListener(_onControllerChanged);
    controller.searchController.addListener(_onSearchChanged);
    _scheduleRestore();
  }

  @override
  void didUpdateWidget(WordDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      oldWidget.controller.searchController.removeListener(_onSearchChanged);
      controller.addListener(_onControllerChanged);
      controller.searchController.addListener(_onSearchChanged);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    controller.searchController.removeListener(_onSearchChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (controller.viewMode != _mode) {
      // Keep the paragraph being read in view across the switch.
      final reading = _topParagraph();
      _mode = controller.viewMode;
      _itemHeights.clear();
      _anchors.clear();
      setState(() {});
      if (reading != null) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToParagraph(reading, align: 0));
      return;
    }
    setState(() {});
    _scheduleRestore();
  }

  /// The number of the first paragraph at or below the top of the view.
  ///
  /// Header and footer paragraphs don't count: on pages they're drawn on
  /// every page (registering under their layout numbers, which come before
  /// and after the body), so one could otherwise be "at the top" and send
  /// a layout switch, or the saved paragraph, to the document's start or end.
  int? _topParagraph() {
    final viewport = context.findRenderObject() as RenderBox?;
    final layout = controller.layout;
    if (viewport == null || layout == null) return null;
    final top = viewport.localToGlobal(Offset.zero).dy;
    int? best;
    double bestY = double.infinity;
    _anchors.forEach((number, anchorContext) {
      if (!anchorContext.mounted || number >= layout.itemOfParagraph.length) return;
      final kind = layout.items[layout.itemOfParagraph[number]].kind;
      if (kind == WordItemKind.header || kind == WordItemKind.footer) return;
      final box = anchorContext.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) return;
      final y = box.localToGlobal(Offset.zero).dy;
      final bottom = y + box.size.height * _scaleOf(box);
      if (bottom > top && y < bestY) {
        bestY = y;
        best = number;
      }
    });
    return best;
  }

  /// Once a scroll settles, finds the paragraph at the top - after the
  /// next layout, which puts the paragraphs where the scroll left them - and
  /// reports the position again with it. Finding it walks the built
  /// paragraphs, so reports during a scroll carry the last one found.
  void _reportTopParagraph() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.scrollController.hasClients) return;
      final paragraph = _topParagraph();
      if (paragraph == null || paragraph == _readingParagraph) return;
      _readingParagraph = paragraph;
      controller.onScrollOffsetChanged(controller.scrollController.offset, topParagraph: paragraph);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// How much a box is scaled on screen (pages are drawn scaled down).
  static double _scaleOf(RenderBox box) {
    final transform = box.getTransformTo(null);
    return transform.getMaxScaleOnAxis();
  }

  /// Scrolls to the saved offset once the document is on screen. The list
  /// only knows its full length as it builds, so keep trying for a few
  /// frames until the offset is reachable.
  void _scheduleRestore([int attempt = 0]) {
    if (_restored || controller.layout == null) return;
    final target = controller.initialScrollOffset;
    if (target <= 0) {
      _restored = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.scrollController.hasClients) return;
      final position = controller.scrollController.position;
      position.jumpTo(math.min(target, position.maxScrollExtent));
      if (position.pixels >= target - 1 || attempt >= 12) {
        _restored = true;
      } else {
        _scheduleRestore(attempt + 1);
      }
    });
  }

  void _onSearchChanged() {
    final match = controller.searchController.currentMatch;
    if (match == null) {
      _lastMatchKey = null;
      return;
    }
    final key = Object.hash(controller.searchController.query, controller.searchController.currentMatchIndex);
    if (key == _lastMatchKey) return;
    _lastMatchKey = key;
    _jumpToParagraph(match.paragraph);
  }

  /// The list item showing paragraph [number] in the current layout.
  int? _itemOf(int number) {
    final layout = controller.layout;
    if (layout == null) return null;
    if (_mode == WordViewMode.paged) {
      // Headers and footers aren't placed on a page of their own: use the
      // first body paragraph after this one.
      final pages = _pagination?.pageOfParagraph;
      if (pages == null) return null;
      for (var n = number; n < layout.paragraphs.length; n++) {
        if (pages[n] case final page?) return page;
      }
      return null;
    }
    return number < layout.itemOfParagraph.length ? layout.itemOfParagraph[number] : null;
  }

  /// Brings paragraph [number] into view: directly when it's built,
  /// otherwise by jumping to an estimate first.
  void _jumpToParagraph(int number, {double align = 0.25, int attempt = 0}) {
    if (!mounted) return;
    final anchor = _anchors[number];
    if (anchor != null && anchor.mounted) {
      Scrollable.ensureVisible(anchor, alignment: align, duration: const Duration(milliseconds: 200));
      return;
    }
    final item = _itemOf(number);
    if (item == null || attempt >= 4 || !controller.scrollController.hasClients) return;
    final known = _itemHeights.values;
    final average = known.isEmpty ? 48.0 : known.reduce((a, b) => a + b) / known.length;
    var estimate = 0.0;
    for (var i = 0; i < item; i++) {
      estimate += _itemHeights[i] ?? average;
    }
    final position = controller.scrollController.position;
    position.jumpTo(estimate.clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToParagraph(number, align: align, attempt: attempt + 1));
  }

  void _onLink(WordLink link) {
    final anchor = link.anchor;
    final bookmark = anchor == null ? null : controller.layout?.bookmarks[anchor];
    if (bookmark != null) {
      _jumpToParagraph(bookmark);
      return;
    }
    final uri = link.url == null ? null : Uri.tryParse(link.url!);
    if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _onNote(WordNoteReference reference) {
    final document = controller.document;
    if (document == null) return;
    final blocks = (reference.kind == NoteKind.footnote ? document.footnotes : document.endnotes)[reference.id];
    if (blocks == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => WordScope(
        layout: controller.layout!,
        search: controller.searchController,
        onLink: _onLink,
        onNote: (_) {},
        // Paragraphs in the sheet aren't jump targets.
        anchors: <int, BuildContext>{},
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              children: [for (final block in blocks) WordBlockView(block)],
            ),
          ),
        ),
      ),
    );
  }

  /// Pages for the current document and text scale, worked out once.
  WordPagination _paginate(WordDocumentLayout layout) {
    final textScaler = MediaQuery.textScalerOf(context);
    final key = (layout, textScaler);
    if (_pagination != null && _paginationKey == key) return _pagination!;
    final styler = WordParagraphStyler(scheme: WordPageView.paper.colorScheme, linkColor: layout.document.linkColor, pageNumber: 1, pageCount: 1);
    _pagination = WordPaginator(layout, WordMeasurer(styler, textScaler: textScaler)).paginate();
    _paginationKey = key;
    return _pagination!;
  }

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout;
    if (layout == null) return const Center(child: CircularProgressIndicator());
    return WordScope(
      layout: layout,
      search: controller.searchController,
      onLink: _onLink,
      onNote: _onNote,
      anchors: _anchors,
      child: NotificationListener<ScrollNotification>(
        // Only the document's own vertical scroll: wide tables scroll
        // sideways inside it.
        onNotification: (notification) {
          if (notification.depth == 0 && notification.metrics.axis == Axis.vertical && _restored) {
            controller.onScrollOffsetChanged(notification.metrics.pixels, topParagraph: _readingParagraph);
            if (notification is ScrollEndNotification) _reportTopParagraph();
          }
          return false;
        },
        child: _mode == WordViewMode.paged ? _buildPages(layout) : _buildContinuous(layout),
      ),
    );
  }

  Widget _measured(int index, Widget child) =>
      _SizeReporter(onSize: (size) => _itemHeights[index] = size.height, child: child);

  Widget _buildContinuous(WordDocumentLayout layout) {
    final firstNote = layout.firstNoteItem;
    final items = layout.items;
    return ListView.builder(
      key: const PageStorageKey('continuous'),
      controller: controller.scrollController,
      padding: widget.padding,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        Widget child = WordBlockView(item.block);
        if (item.kind == WordItemKind.header || item.kind == WordItemKind.footer) {
          child = DefaultTextStyle.merge(style: const TextStyle(fontSize: 12), child: child);
        }
        final previous = index == 0 ? null : items[index - 1].kind;
        final children = [
          if (index == firstNote) ...[
            const Divider(height: 32),
            Text('Notes', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
          ] else if (item.kind == WordItemKind.footer && previous != WordItemKind.footer)
            const Divider(height: 32),
          child,
          if (item.kind == WordItemKind.header && (index + 1 >= items.length || items[index + 1].kind != WordItemKind.header))
            const Divider(height: 32),
        ];
        return _measured(
          index,
          children.length == 1 ? child : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        );
      },
    );
  }

  Widget _buildPages(WordDocumentLayout layout) {
    final pagination = _paginate(layout);
    final pages = pagination.pages;
    return ListView.builder(
      key: const PageStorageKey('paged'),
      controller: controller.scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      itemCount: pages.length,
      itemBuilder: (context, index) => _measured(
        index,
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Theme(
                data: WordPageView.paper,
                child: WordPageInfo(
                  number: index + 1,
                  count: pages.length,
                  child: WordPageView(pages[index]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One page on paper: the body at the page's margins, the header and footer
/// in the margins above and below. Shown under [paper], a [WordScope] and a
/// [WordPageInfo]; also drawn offscreen for a document's thumbnail.
class WordPageView extends StatelessWidget {
  const WordPageView(this.page, {super.key});

  final WordPage page;

  /// The paper pages are drawn on: dark text on white, whatever the app
  /// theme, as in print.
  static final paper = ThemeData(colorScheme: const ColorScheme.light(surface: Colors.white, onSurface: Colors.black));

  @override
  Widget build(BuildContext context) {
    final section = page.section;
    final header = page.header;
    final footer = page.footer;
    final left = section.marginLeft * wordScale;
    final right = section.marginRight * wordScale;
    // Headers and footers sit half an inch from the page edge by default.
    const edge = 36 * wordScale;
    return Material(
      color: Colors.white,
      elevation: 1,
      child: SizedBox(
        width: page.width,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: page.height),
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(left, section.marginTop * wordScale, right, section.marginBottom * wordScale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in page.entries)
                      switch (entry.block) {
                        final WordParagraph paragraph when entry.number != null =>
                          WordParagraphView(paragraph, number: entry.number, textOffset: entry.textOffset),
                        final block => WordBlockView(block),
                      },
                  ],
                ),
              ),
              if (header != null)
                Positioned(
                  top: edge,
                  left: left,
                  right: right,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final b in header) WordBlockView(b)]),
                ),
              if (footer != null)
                Positioned(
                  bottom: edge,
                  left: left,
                  right: right,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final b in footer) WordBlockView(b)]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reports its child's laid-out size (for estimating scroll positions).
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}
