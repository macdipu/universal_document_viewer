// Internal to MarkdownView: not exported, so its members need no public docs.
// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../common/document_viewer_strings.dart';
import 'markdown_highlighter.dart';

/// Renders Markdown source with native widgets: headings, lists, tables,
/// images, links, quotes, task lists and highlighted code blocks.
///
/// Top-level blocks are built lazily, so a long document scrolls smoothly.
/// Relative image paths resolve against [baseDirectory] (the file's folder).
class MarkdownPreview extends StatefulWidget {
  final List<String> lines;
  final String? baseDirectory;
  final double fontSize;
  final ScrollController controller;

  /// Past this many characters the preview stops and says so; Code mode still
  /// shows everything. Keeps parsing a huge file from freezing the UI.
  static const int maxPreviewChars = 1000000;

  const MarkdownPreview({
    super.key,
    required this.lines,
    required this.baseDirectory,
    required this.fontSize,
    required this.controller,
  });

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  List<md.Node> _blocks = const [];
  bool _truncated = false;
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MarkdownPreview old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines)) _parse();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  void _parse() {
    var budget = MarkdownPreview.maxPreviewChars;
    var count = 0;
    for (final line in widget.lines) {
      budget -= line.length + 1;
      if (budget < 0) break;
      count++;
    }
    _truncated = count < widget.lines.length;
    try {
      _blocks = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false)
          .parseLines(widget.lines.sublist(0, count));
    } catch (_) {
      // Malformed input must never break the reader: show it as plain text.
      _blocks = [
        md.Element('p', [md.Text(widget.lines.sublist(0, count).join('\n'))])
      ];
    }
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final ctx = _Ctx(
      theme: theme,
      palette: SyntaxPalette.of(context),
      fontSize: widget.fontSize,
      baseDirectory: widget.baseDirectory,
      recognizers: _recognizers,
    );
    return Container(
      color: theme.colorScheme.surface,
      child: SelectionArea(
        child: ListView.builder(
          controller: widget.controller,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          itemCount: _blocks.length + (_truncated ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == _blocks.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  DocumentViewerStrings.of(context).markdownPreviewTruncated,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              );
            }
            return Padding(padding: const EdgeInsets.only(bottom: 12), child: ctx.block(_blocks[i]));
          },
        ),
      ),
    );
  }
}

class _Ctx {
  final ThemeData theme;
  final SyntaxPalette palette;
  final double fontSize;
  final String? baseDirectory;
  final List<TapGestureRecognizer> recognizers;

  _Ctx({
    required this.theme,
    required this.palette,
    required this.fontSize,
    required this.baseDirectory,
    required this.recognizers,
  });

  ColorScheme get scheme => theme.colorScheme;

  TextStyle get body => (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: fontSize,
        height: 1.55,
        color: scheme.onSurface,
      );

  TextStyle get mono => body.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier'],
      fontSize: fontSize * 0.88,
      height: 1.45);

  static const _headingScale = {'h1': 1.9, 'h2': 1.55, 'h3': 1.3, 'h4': 1.15, 'h5': 1.05, 'h6': 0.95};

  // ---- Blocks

  Widget block(md.Node node, {TextStyle? style}) {
    if (node is md.Text) {
      return Text.rich(TextSpan(text: node.text, style: style ?? body));
    }
    final e = node as md.Element;
    final base = style ?? body;
    switch (e.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final s = base.copyWith(fontSize: fontSize * _headingScale[e.tag]!, fontWeight: FontWeight.w700, height: 1.3);
        final heading = Padding(
          padding: EdgeInsets.only(top: e.tag == 'h1' || e.tag == 'h2' ? 8 : 4),
          child: Text.rich(TextSpan(children: inline(e.children, s), style: s)),
        );
        if (e.tag == 'h1' || e.tag == 'h2') {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [heading, const SizedBox(height: 6), Divider(height: 1, color: scheme.outlineVariant)],
          );
        }
        return heading;
      case 'p':
        return Text.rich(TextSpan(children: inline(e.children, base), style: base));
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outline, width: 3))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in e.children ?? const <md.Node>[])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: block(c, style: base.copyWith(color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
        );
      case 'ul':
      case 'ol':
        return list(e, base, 0);
      case 'pre':
        return codeBlock(e);
      case 'hr':
        return Divider(height: 24, color: scheme.outlineVariant);
      case 'table':
        return table(e, base);
      default:
        // Unknown block (raw HTML etc.): show its text rather than dropping it.
        final kids = e.children;
        if (kids == null || kids.isEmpty) return const SizedBox.shrink();
        return Text.rich(TextSpan(children: inline(kids, base), style: base));
    }
  }

  Widget list(md.Element e, TextStyle base, int depth) {
    final ordered = e.tag == 'ol';
    var number = int.tryParse(e.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final child in e.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      final kids = child.children ?? const <md.Node>[];
      // A task list item starts with an `input` checkbox element.
      md.Element? checkbox;
      if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'input') {
        checkbox = kids.first as md.Element;
      } else if (kids.isNotEmpty && kids.first is md.Element && (kids.first as md.Element).tag == 'p') {
        final first = (kids.first as md.Element).children;
        if (first != null &&
            first.isNotEmpty &&
            first.first is md.Element &&
            (first.first as md.Element).tag == 'input') {
          checkbox = first.first as md.Element;
        }
      }
      final Widget marker;
      if (checkbox != null) {
        final checked = checkbox.attributes.containsKey('checked');
        marker = Icon(
          checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
          size: fontSize * 1.2,
          color: checked ? scheme.primary : scheme.onSurfaceVariant,
        );
      } else {
        marker = Text(ordered ? '${number++}.' : (depth == 0 ? '•' : (depth == 1 ? '◦' : '▪')), style: base);
      }
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: ordered ? 28 : 20,
                  child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(padding: const EdgeInsets.only(right: 6), child: marker))),
              Expanded(child: listItemBody(kids, base, depth, checkbox)),
            ],
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items);
  }

  Widget listItemBody(List<md.Node> kids, TextStyle base, int depth, md.Element? checkbox) {
    // Consecutive inline nodes form one paragraph; block children stack.
    final widgets = <Widget>[];
    final run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      widgets.add(Text.rich(TextSpan(children: inline(List.of(run), base), style: base)));
      run.clear();
    }

    for (final k in kids) {
      if (k is md.Element && k.tag == 'input') continue;
      if (k is md.Element && (k.tag == 'ul' || k.tag == 'ol')) {
        flush();
        widgets.add(Padding(padding: const EdgeInsets.only(top: 4), child: list(k, base, depth + 1)));
      } else if (k is md.Element && k.tag == 'p') {
        flush();
        final children =
            (k.children ?? const <md.Node>[]).where((c) => !(c is md.Element && c.tag == 'input')).toList();
        widgets.add(Text.rich(TextSpan(children: inline(children, base), style: base)));
      } else if (k is md.Element && !_inlineTags.contains(k.tag)) {
        flush();
        widgets.add(block(k, style: base));
      } else {
        run.add(k);
      }
    }
    flush();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widgets);
  }

  static const _inlineTags = {'em', 'strong', 'del', 'code', 'a', 'img', 'br', 'input'};

  Widget codeBlock(md.Element pre) {
    final code = (pre.children?.firstOrNull is md.Element) ? pre.children!.first as md.Element : null;
    var text = code?.textContent ?? pre.textContent;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    final cls = code?.attributes['class'] ?? '';
    final language = cls.startsWith('language-') ? cls.substring(9) : null;
    final spans = CodeHighlighter.highlight(text, language, palette);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (language != null && language.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(language, style: mono.copyWith(fontSize: fontSize * 0.75, color: scheme.onSurfaceVariant)),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Text.rich(TextSpan(children: spans, style: mono)),
          ),
        ],
      ),
    );
  }

  Widget table(md.Element e, TextStyle base) {
    final rows = <TableRow>[];
    var columns = 0;
    void addRows(md.Element? section, {required bool header}) {
      for (final tr in section?.children ?? const <md.Node>[]) {
        if (tr is! md.Element || tr.tag != 'tr') continue;
        final cells = <Widget>[];
        for (final cell in tr.children ?? const <md.Node>[]) {
          if (cell is! md.Element) continue;
          final style = cell.tag == 'th' ? base.copyWith(fontWeight: FontWeight.w700) : base;
          final align = cell.attributes['style'] ?? cell.attributes['align'] ?? '';
          final textAlign = align.contains('right')
              ? TextAlign.right
              : (align.contains('center') ? TextAlign.center : TextAlign.left);
          cells.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text.rich(TextSpan(children: inline(cell.children, style), style: style), textAlign: textAlign),
            ),
          );
        }
        if (cells.length > columns) columns = cells.length;
        rows.add(TableRow(
          decoration: header ? BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.6)) : null,
          children: cells,
        ));
      }
    }

    for (final section in e.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      addRows(section, header: section.tag == 'thead');
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    // Ragged rows: pad so Table's equal-length requirement holds.
    final padded = [
      for (final r in rows)
        TableRow(
          decoration: r.decoration,
          children: [...r.children, for (var i = r.children.length; i < columns; i++) const SizedBox.shrink()],
        ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: scheme.outlineVariant),
        children: padded,
      ),
    );
  }

  // ---- Inline

  List<InlineSpan> inline(List<md.Node>? nodes, TextStyle style) {
    final out = <InlineSpan>[];
    for (final n in nodes ?? const <md.Node>[]) {
      if (n is md.Text) {
        out.add(TextSpan(text: n.text));
        continue;
      }
      final e = n as md.Element;
      switch (e.tag) {
        case 'em':
          out.add(TextSpan(children: inline(e.children, style), style: const TextStyle(fontStyle: FontStyle.italic)));
        case 'strong':
          out.add(TextSpan(children: inline(e.children, style), style: const TextStyle(fontWeight: FontWeight.w700)));
        case 'del':
          out.add(TextSpan(
              children: inline(e.children, style), style: const TextStyle(decoration: TextDecoration.lineThrough)));
        case 'code':
          out.add(TextSpan(
            text: e.textContent,
            style: mono.copyWith(
                backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.7), color: palette.string),
          ));
        case 'br':
          out.add(const TextSpan(text: '\n'));
        case 'a':
          final href = e.attributes['href'];
          final recognizer = TapGestureRecognizer()..onTap = () => _open(href);
          recognizers.add(recognizer);
          out.add(TextSpan(
            children: inline(e.children, style),
            recognizer: recognizer,
            style:
                TextStyle(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary),
          ));
        case 'img':
          out.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle, child: image(e.attributes['src'], e.attributes['alt'])));
        case 'input':
          final checked = e.attributes.containsKey('checked');
          out.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: fontSize * 1.2, color: scheme.primary),
          ));
        default:
          // Raw HTML such as <b> or <details>: keep the text.
          out.addAll(inline(e.children, style));
      }
    }
    return out;
  }

  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  Future<void> _open(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto')) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No handler for the link; nothing to do.
    }
  }

  Widget image(String? src, String? alt) {
    final fallback = _ImageFallback(alt: alt, src: src, color: scheme.onSurfaceVariant);
    if (src == null || src.isEmpty) return fallback;
    const constraints = BoxConstraints(maxHeight: 480);
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return ConstrainedBox(
        constraints: constraints,
        child: Image.network(src, errorBuilder: (_, _, _) => fallback, fit: BoxFit.contain),
      );
    }
    if (kIsWeb || src.startsWith('data:')) return fallback;
    final decoded = _decode(src);
    final path = _scheme.hasMatch(decoded) && !p.isAbsolute(decoded)
        ? (decoded.startsWith('file:') ? Uri.tryParse(decoded)?.toFilePath() : null)
        : (p.isAbsolute(decoded)
            ? decoded
            : (baseDirectory == null ? null : p.normalize(p.join(baseDirectory!, decoded))));
    if (path == null) return fallback;
    final lower = path.toLowerCase();
    if (lower.endsWith('.svg')) return fallback;
    return ConstrainedBox(
      constraints: constraints,
      child: Image.file(File(path), errorBuilder: (_, _, _) => fallback, fit: BoxFit.contain),
    );
  }

  String _decode(String src) {
    // Markdown images often carry %20 for spaces.
    try {
      final noQuery = src.split('#').first.split('?').first;
      return Uri.decodeFull(noQuery);
    } catch (_) {
      return src;
    }
  }
}

class _ImageFallback extends StatelessWidget {
  final String? alt;
  final String? src;
  final Color color;

  const _ImageFallback({required this.alt, required this.src, required this.color});

  @override
  Widget build(BuildContext context) {
    final label = (alt != null && alt!.isNotEmpty) ? alt! : (src ?? 'image');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.image_not_supported_outlined, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(
            child: Text(label,
                style: TextStyle(color: color, fontStyle: FontStyle.italic), overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
