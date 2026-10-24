import 'package:flutter/material.dart';

import 'text_document_controller.dart';
import 'text_line_metrics.dart';

/// A plain-text document as scrolling lines, with search matches
/// highlighted. Restores [TextDocumentController.initialScrollOffset] once
/// laid out and reports scrolling to the controller.
class TextDocumentView extends StatefulWidget {
  const TextDocumentView({super.key, required this.controller, this.fontSize = 14, this.wrap = true});

  final TextDocumentController controller;
  final double fontSize;

  /// Wrap long lines; when false each line scrolls horizontally.
  final bool wrap;

  @override
  State<TextDocumentView> createState() => _TextDocumentViewState();
}

class _TextDocumentViewState extends State<TextDocumentView> {
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
  void dispose() {
    widget.controller.scrollController.removeListener(_onScroll);
    widget.controller.lineOffsetResolver = null;
    widget.controller.lineAtOffsetResolver = null;
    super.dispose();
  }

  static const _rowPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 2);

  TextLineMetrics? _metrics;

  /// Keeps the controller's jump-to-match offsets measured against what is
  /// actually laid out (UX-21); re-measured only when an input changes.
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
        final lines = widget.controller.lines;
        final query = widget.controller.searchQuery;
        final fontSize = widget.fontSize;
        final wrap = widget.wrap;
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
                  child: _TextLine(text: lines[index], fontSize: fontSize, wrap: wrap, highlightQuery: query),
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

  const _TextLine({required this.text, required this.fontSize, required this.wrap, required this.highlightQuery});

  /// Shared with [TextLineMetrics] measurement, which must match it.
  static TextStyle styleFor(BuildContext context, double fontSize) =>
      Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(fontSize: fontSize, color: Theme.of(context).colorScheme.onSurface) ??
      TextStyle(fontSize: fontSize, color: Theme.of(context).colorScheme.onSurface);

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
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
      );
      start = index + query.length;
    }
    return TextSpan(style: style, children: spans);
  }
}
