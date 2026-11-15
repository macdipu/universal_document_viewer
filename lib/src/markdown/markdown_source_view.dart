// Internal to MarkdownView: not exported, so its members need no public docs.
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

import '../common/document_viewer_theme.dart';
import '../common/match_spans.dart';
import '../common/text_lines_controller.dart';
import 'markdown_highlighter.dart';

/// Code mode: raw Markdown with syntax colouring, a line-number gutter, text
/// selection and search highlights (the match state lives on [search], the
/// same controller the plain-text reader uses).
///
/// Every line has one fixed height and long lines scroll sideways together,
/// so scroll positions, line jumps and match jumps are exact even for very
/// large files.
class MarkdownSourceView extends StatefulWidget {
  final List<String> lines;
  final TextLinesController search;
  final double fontSize;
  final ScrollController controller;

  const MarkdownSourceView({
    super.key,
    required this.lines,
    required this.search,
    required this.fontSize,
    required this.controller,
  });

  /// Line height as a multiple of the font size.
  static const double lineHeightFactor = 1.5;

  @override
  State<MarkdownSourceView> createState() => _MarkdownSourceViewState();
}

class _MarkdownSourceViewState extends State<MarkdownSourceView> {
  late MarkdownSourceHighlighter _highlighter = MarkdownSourceHighlighter(widget.lines);
  late int _longest = _longestLine();
  int _lastMatch = -1;
  String _lastQuery = '';

  int _longestLine() {
    var longest = 0;
    for (final l in widget.lines) {
      if (l.length > longest) longest = l.length;
    }
    // A pathological line must not make an enormous scroll extent.
    return longest.clamp(0, 4000);
  }

  @override
  void initState() {
    super.initState();
    widget.search.addListener(_onSearch);
    // Mounted by a search from Preview: the match was found before this view
    // existed, so scroll to it once laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onSearch(force: true);
    });
  }

  @override
  void didUpdateWidget(MarkdownSourceView old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines)) {
      _highlighter = MarkdownSourceHighlighter(widget.lines);
      _longest = _longestLine();
    }
    if (old.search != widget.search) {
      old.search.removeListener(_onSearch);
      widget.search.addListener(_onSearch);
    }
  }

  @override
  void dispose() {
    widget.search.removeListener(_onSearch);
    super.dispose();
  }

  double get _lineHeight => widget.fontSize * MarkdownSourceView.lineHeightFactor;

  /// Scrolls to the current match when it changes (a new query or next/previous).
  void _onSearch({bool force = false}) {
    final index = widget.search.currentMatch;
    final query = widget.search.searchQuery;
    final changed = index != _lastMatch || query != _lastQuery;
    _lastMatch = index;
    _lastQuery = query;
    if ((!changed && !force) || index < 0 || !widget.controller.hasClients) return;
    final line = widget.search.matches[index].line;
    final position = widget.controller.position;
    final top = line * _lineHeight;
    final visibleTop = position.pixels;
    final visibleBottom = visibleTop + position.viewportDimension - _lineHeight;
    if (top < visibleTop || top > visibleBottom) {
      widget.controller.animateTo(
        (top - position.viewportDimension / 3).clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = SyntaxPalette.of(context);
    final fontSize = widget.fontSize;
    final mono = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier'],
      fontSize: fontSize,
      height: 1,
      color: scheme.onSurface,
    );
    final charWidth = fontSize * 0.62;
    final digits = widget.lines.length.toString().length.clamp(2, 8);
    final gutterWidth = digits * charWidth + 20;
    final highlights = DocumentViewerTheme.of(context);

    return Container(
      color: scheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = _longest * charWidth + 32;
          final width = (gutterWidth + contentWidth).clamp(constraints.maxWidth, double.infinity);
          return SelectionArea(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                height: constraints.maxHeight,
                child: ListenableBuilder(
                  listenable: widget.search,
                  builder: (context, _) {
                    final query = widget.search.searchQuery;
                    final current = widget.search.currentTextMatch;
                    return ListView.builder(
                      controller: widget.controller,
                      itemExtent: _lineHeight,
                      itemCount: widget.lines.length,
                      itemBuilder: (context, i) {
                        final line = widget.lines[i];
                        final List<InlineSpan> spans = query.isEmpty
                            ? _highlighter.spansFor(i, palette)
                            : matchSpans(
                                line,
                                query,
                                highlights,
                                currentStart: current?.line == i ? current!.start : null,
                              );
                        return Row(
                          children: [
                            SelectionContainer.disabled(
                              child: Container(
                                width: gutterWidth,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 10),
                                color: scheme.surfaceContainerLow,
                                child: Text(
                                  '${i + 1}',
                                  style: mono.copyWith(
                                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                                    fontSize: fontSize * 0.9,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: Text.rich(
                                  TextSpan(children: spans, style: mono),
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.clip,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
