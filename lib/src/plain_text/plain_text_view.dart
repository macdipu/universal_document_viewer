import 'package:flutter/material.dart';

import '../common/document_viewer_theme.dart';
import 'plain_text_controller.dart';
import 'text_line_metrics.dart';

/// Shows a [PlainTextController]'s document as scrolling lines.
///
/// Long lines wrap or scroll sideways ([PlainTextController.wrap]); the
/// text is [fontSize] times [PlainTextController.zoom]. Search matches are
/// highlighted, the current one apart from the rest. Reopens at
/// [PlainTextController.initialScrollOffset] and reports scrolling back to
/// the controller.
class PlainTextView extends StatefulWidget {
  /// Shows [controller]'s document, at [fontSize] before zoom.
  const PlainTextView({super.key, required this.controller, this.fontSize = 16});

  /// The document to show.
  final PlainTextController controller;

  /// The text size at zoom 1, in logical pixels.
  final double fontSize;

  @override
  State<PlainTextView> createState() => _PlainTextViewState();
}

class _PlainTextViewState extends State<PlainTextView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreInitialOffset());
    widget.controller.scrollController.addListener(_onScroll);
  }

  void _onScroll() => widget.controller.onScrolled(widget.controller.scrollController.offset);

  void _restoreInitialOffset() {
    final controller = widget.controller;
    if (controller.scrollController.hasClients && controller.initialScrollOffset > 0) {
      final max = controller.scrollController.position.maxScrollExtent;
      controller.scrollController.jumpTo(controller.initialScrollOffset.clamp(0.0, max));
    }
  }

  @override
  void didUpdateWidget(PlainTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.scrollController.removeListener(_onScroll);
    oldWidget.controller.lineOffsetResolver = null;
    oldWidget.controller.lineAtOffsetResolver = null;
    widget.controller.scrollController.addListener(_onScroll);
    _metrics = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreInitialOffset();
    });
  }

  @override
  void dispose() {
    widget.controller.scrollController.removeListener(_onScroll);
    widget.controller.lineOffsetResolver = null;
    widget.controller.lineAtOffsetResolver = null;
    super.dispose();
  }

  static const _rowPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 2);

  TextLineMetrics? _metrics;

  /// Keeps the controller's jump-to-match offsets measured against what is
  /// actually laid out; re-measured only when an input changes.
  void _attachMetrics(BuildContext context, double width, double fontSize, bool wrap) {
    final lines = widget.controller.lines;
    // No bold-text merge: jumps only happen with a search query, when rows
    // render via `Text.rich` with this explicit-weight style, which the
    // system bold-text setting doesn't override.
    final style = DefaultTextStyle.of(context).style.merge(_TextLine.styleFor(context, fontSize));
    final textScaler = MediaQuery.textScalerOf(context);
    final contentWidth = width - _rowPadding.horizontal;
    final current = _metrics;
    if (current == null ||
        !current.matches(lines: lines, style: style, textScaler: textScaler, contentWidth: contentWidth, wrap: wrap)) {
      _metrics = TextLineMetrics(
        lines: lines,
        style: style,
        textScaler: textScaler,
        contentWidth: contentWidth,
        wrap: wrap,
        verticalPadding: _rowPadding.vertical,
      );
    }
    widget.controller
      ..lineOffsetResolver = _metrics!.offsetOf
      ..lineAtOffsetResolver = _metrics!.lineAt;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        // A go-to asked for before the lines were laid out.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.controller.applyPending();
        });
        final lines = widget.controller.lines;
        final query = widget.controller.searchQuery;
        final current = widget.controller.currentTextMatch;
        final fontSize = widget.fontSize * widget.controller.zoom;
        final wrap = widget.controller.wrap;
        return Container(
          color: Theme.of(context).colorScheme.surface,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _attachMetrics(context, constraints.maxWidth, fontSize, wrap);
              return ListView.builder(
                controller: widget.controller.scrollController,
                itemCount: lines.length,
                itemBuilder: (context, index) => Padding(
                  padding: _rowPadding,
                  child: _TextLine(
                    text: lines[index],
                    fontSize: fontSize,
                    wrap: wrap,
                    highlightQuery: query,
                    currentMatchStart: current?.line == index ? current!.start : null,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _TextLine extends StatelessWidget {
  final String text;
  final double fontSize;
  final bool wrap;
  final String highlightQuery;

  /// Where the search's current match starts, when it's on this line: that
  /// occurrence stands out from the others.
  final int? currentMatchStart;

  const _TextLine({
    required this.text,
    required this.fontSize,
    required this.wrap,
    required this.highlightQuery,
    this.currentMatchStart,
  });

  /// Room between lines for comfortable reading.
  static const lineHeight = 1.45;

  /// Shared with [TextLineMetrics] measurement, which must match it.
  static TextStyle styleFor(BuildContext context, double fontSize) =>
      Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontSize: fontSize,
        height: lineHeight,
        color: Theme.of(context).colorScheme.onSurface,
      ) ??
      TextStyle(fontSize: fontSize, height: lineHeight, color: Theme.of(context).colorScheme.onSurface);

  @override
  Widget build(BuildContext context) {
    final style = styleFor(context, fontSize);
    final content = highlightQuery.isEmpty
        ? Text(text, style: style, softWrap: wrap, overflow: wrap ? TextOverflow.visible : TextOverflow.clip)
        : Text.rich(
            _highlighted(text, highlightQuery, style, context),
            softWrap: wrap,
            overflow: wrap ? TextOverflow.visible : TextOverflow.clip,
          );
    return wrap ? content : SingleChildScrollView(scrollDirection: Axis.horizontal, child: content);
  }

  TextSpan _highlighted(String text, String query, TextStyle style, BuildContext context) {
    final highlights = DocumentViewerTheme.of(context);
    final lower = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(lowerQuery, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) spans.add(TextSpan(text: text.substring(start, index)));
      final isCurrentMatch = index == currentMatchStart;
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: highlights.matchStyle(current: isCurrentMatch),
        ),
      );
      start = index + query.length;
    }
    return TextSpan(style: style, children: spans);
  }
}
