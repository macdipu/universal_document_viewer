import 'package:flutter/material.dart';

import 'markdown_controller.dart';
import 'markdown_preview.dart';
import 'markdown_source_view.dart';
import 'markdown_stats.dart';

/// Shows a [MarkdownController]'s document as a rendered preview, as
/// highlighted source with line numbers, or both side by side, as
/// [MarkdownController.viewMode] says.
///
/// The text is [fontSize] times [MarkdownController.zoom]. Split puts the
/// source and preview next to each other on wide areas and stacks them on
/// narrow ones, with a draggable divider; scrolling one scrolls the other by
/// position in the document. Relative image paths resolve against
/// [MarkdownController.baseDirectory].
class MarkdownView extends StatefulWidget {
  /// Shows [controller]'s document, at [fontSize] before zoom.
  const MarkdownView({super.key, required this.controller, this.fontSize = 16});

  /// The document to show.
  final MarkdownController controller;

  /// The text size at zoom 1, in logical pixels.
  final double fontSize;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final _preview = ScrollController();
  final _source = ScrollController();

  late double _ratio = widget.controller.initialRatio;
  bool _syncing = false;
  double _splitFraction = 0.5;

  MarkdownController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _preview.addListener(() => _onScroll(_preview));
    _source.addListener(() => _onScroll(_source));
    c.viewMode.addListener(_restoreAfterLayout);
    c.lineJumper = _jumpToLine;
    _restoreAfterLayout();
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.controller == c) return;
    old.controller.viewMode.removeListener(_restoreAfterLayout);
    old.controller.lineJumper = null;
    c.viewMode.addListener(_restoreAfterLayout);
    c.lineJumper = _jumpToLine;
    _ratio = c.initialRatio;
    _restoreAfterLayout();
  }

  @override
  void dispose() {
    c.viewMode.removeListener(_restoreAfterLayout);
    if (c.lineJumper == _jumpToLine) c.lineJumper = null;
    _preview.dispose();
    _source.dispose();
    super.dispose();
  }

  void _restoreAfterLayout() {
    // Twice: the first frame lays the lists out, the second knows their extents.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyRatio();
      c.applyPending();
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyRatio());
    });
  }

  void _applyRatio() {
    if (!mounted) return;
    _syncing = true;
    for (final s in [_preview, _source]) {
      if (s.hasClients) s.jumpTo((_ratio * s.position.maxScrollExtent).clamp(0.0, s.position.maxScrollExtent));
    }
    _syncing = false;
  }

  void _onScroll(ScrollController from) {
    if (_syncing || !from.hasClients) return;
    final max = from.position.maxScrollExtent;
    _ratio = max <= 0 ? 0 : (from.position.pixels / max).clamp(0.0, 1.0);
    final other = identical(from, _preview) ? _source : _preview;
    if (c.viewMode.value == MarkdownViewMode.split && other.hasClients) {
      _syncing = true;
      other.jumpTo((_ratio * other.position.maxScrollExtent).clamp(0.0, other.position.maxScrollExtent));
      _syncing = false;
    }
    c.onMarkdownScrolled(_ratio);
  }

  void _jumpToLine(int index) {
    void jump() {
      if (!mounted || !_source.hasClients) return;
      final target = index * widget.fontSize * c.zoom * MarkdownSourceView.lineHeightFactor;
      _source.jumpTo(target.clamp(0.0, _source.position.maxScrollExtent));
    }

    if (_source.hasClients) {
      jump();
    } else {
      // Preview was up: the source mounts on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.viewMode]),
      builder: (context, _) {
        final fontSize = widget.fontSize * c.zoom;
        final lines = c.lines;
        Widget preview() => MarkdownPreview(
              lines: lines,
              baseDirectory: c.baseDirectory,
              fontSize: fontSize,
              controller: _preview,
            );
        Widget source() => MarkdownSourceView(lines: lines, search: c, fontSize: fontSize, controller: _source);
        return switch (c.viewMode.value) {
          MarkdownViewMode.preview => preview(),
          MarkdownViewMode.code => source(),
          MarkdownViewMode.split => _split(source(), preview()),
        };
      },
    );
  }

  Widget _split(Widget source, Widget preview) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth >= 600;
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        const handle = 10.0;
        final first = ((total - handle) * _splitFraction).clamp(80.0, total - handle - 80.0);
        final line = Theme.of(context).colorScheme.outline;
        final divider = MouseRegion(
          cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: horizontal ? (d) => _drag(d.delta.dx, total - handle) : null,
            onVerticalDragUpdate: horizontal ? null : (d) => _drag(d.delta.dy, total - handle),
            child: SizedBox(
              width: horizontal ? handle : null,
              height: horizontal ? null : handle,
              child: Center(
                child: Container(
                  width: horizontal ? 2 : 36,
                  height: horizontal ? 36 : 2,
                  decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(1)),
                ),
              ),
            ),
          ),
        );
        final children = [
          SizedBox(width: horizontal ? first : null, height: horizontal ? null : first, child: source),
          divider,
          Expanded(child: preview),
        ];
        return horizontal ? Row(children: children) : Column(children: children);
      },
    );
  }

  void _drag(double delta, double total) {
    if (total > 0) setState(() => _splitFraction = (_splitFraction + delta / total).clamp(0.15, 0.85));
  }
}
