import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../engines/word/word_model.dart';
import 'word_search_controller.dart';

/// Points -> logical pixels (1 pt = 1/72 in, 1 px = 1/96 in).
const double wordScale = 96 / 72;

/// A paragraph's text as spans, plus what measuring it needs: the size of
/// each inline widget (in order) and how laid-out text offsets map back to
/// [WordParagraph.plainText] offsets.
class ParagraphSpans {
  ParagraphSpans(this.root, this.placeholders, this._segments);

  /// The paragraph's whole text: style root, marker, indent and content.
  final TextSpan root;
  final List<PlaceholderDimensions> placeholders;

  /// (laid-out start, plain start, laid-out length, plain length).
  final List<(int, int, int, int)> _segments;

  /// The [WordParagraph.plainText] offset for a laid-out text offset. An
  /// offset inside an atomic piece (an image, a note mark) snaps to its
  /// start.
  int plainOffsetOf(int laidOut) {
    for (final (start, plain, length, plainLength) in _segments) {
      if (laidOut < start + length) {
        if (laidOut <= start) return plain;
        return length == plainLength ? plain + (laidOut - start) : plain;
      }
    }
    if (_segments.isEmpty) return 0;
    final (_, plain, _, plainLength) = _segments.last;
    return plain + plainLength;
  }
}

/// Where a paragraph's text goes inside a given width, in logical pixels.
/// Shared by the paragraph widget and the page measurer.
class ParagraphGeometry {
  ParagraphGeometry(WordParagraph paragraph, double width) {
    final format = paragraph.format;
    var left = format.indentLeft;
    if (WordParagraphStyler.markerInColumn(paragraph)) {
      markerWidth = WordParagraphStyler.hangingOf(format) * wordScale;
      left = math.max(0, format.indentLeft - WordParagraphStyler.hangingOf(format));
    }
    // Deep indents are scaled for a page, not a phone: never let them take
    // more than 40% of the width.
    final maxIndent = width * 0.4;
    start = math.min(left * wordScale, maxIndent);
    end = math.min(format.indentRight * wordScale, maxIndent / 2);
    final lines = [format.borderTop, format.borderBottom, format.borderLeft, format.borderRight];
    decorated = format.fill != null || lines.any((b) => b != null && b.width > 0);
    double side(BorderLine? line) => line == null || line.width == 0 || line.width * wordScale < 1 ? 0 : line.width * wordScale;
    if (decorated) {
      boxHorizontal = 8 + side(format.borderLeft) + side(format.borderRight);
      boxVertical = 4 + side(format.borderTop) + side(format.borderBottom);
    }
    textWidth = math.max(1, width - start - end - markerWidth - boxHorizontal);
    spaceBefore = format.spaceBefore * wordScale;
    spaceAfter = format.spaceAfter * wordScale;
  }

  double start = 0;
  double end = 0;
  double markerWidth = 0;
  bool decorated = false;

  /// Fill/border box padding plus border widths, horizontally/vertically.
  double boxHorizontal = 0;
  double boxVertical = 0;
  late final double textWidth;
  late final double spaceBefore;
  late final double spaceAfter;

  /// Height around the text: spacing and the box.
  double get chrome => spaceBefore + spaceAfter + boxVertical;
}

/// Turns paragraphs into styled text, for the paragraph widget and for the
/// page measurer alike, so what is measured is what is drawn.
class WordParagraphStyler {
  WordParagraphStyler({required this.scheme, required this.linkColor, this.pageNumber, this.pageCount});

  final ColorScheme scheme;

  /// The document theme's hyperlink colour (0xAARRGGBB).
  final int linkColor;

  /// Set in a paged view: what `PAGE`/`NUMPAGES` fields show.
  final int? pageNumber;
  final int? pageCount;

  /// Line height for a paragraph, as a multiple of its font size.
  static double lineHeightOf(ParagraphFormat format, double firstSize) => switch (format.lineSpacingRule) {
        // Word's single spacing is about 1.15x the font size for its default
        // fonts; multiples scale that.
        LineSpacingRule.auto => 1.15 * format.lineSpacing,
        LineSpacingRule.exact => (format.lineSpacing / firstSize).clamp(0.8, 4.0),
        LineSpacingRule.atLeast => math.max(1.15, format.lineSpacing / firstSize).clamp(1.0, 4.0),
      };

  static double firstSizeOf(WordParagraph paragraph) =>
      paragraph.inlines.whereType<WordText>().firstOrNull?.format.size ?? paragraph.marker?.format.size ?? 11;

  static TextAlign textAlignOf(ParagraphFormat format) => switch (format.alignment) {
        ParagraphAlignment.left => TextAlign.start,
        ParagraphAlignment.center => TextAlign.center,
        ParagraphAlignment.right => TextAlign.end,
        ParagraphAlignment.justify => TextAlign.justify,
      };

  /// The marker hangs in its own column for a tab suffix; otherwise it's
  /// part of the text.
  static bool markerInColumn(WordParagraph paragraph) =>
      paragraph.marker != null && paragraph.marker!.suffix == ListMarkerSuffix.tab;

  /// Width of the hanging marker column, in points.
  static double hangingOf(ParagraphFormat format) => format.firstLineIndent < 0 ? -format.firstLineIndent : 18.0;

  /// The paragraph as spans. [highlights] are in plain-text offsets,
  /// shifted by [textOffset] for a paragraph that continues one split
  /// across pages. [tap] makes recognizers (the widget owns and disposes
  /// them); null when measuring. [imageWidth] caps images, as the widget
  /// does.
  ParagraphSpans spans(
    WordParagraph paragraph, {
    List<WordHighlight> highlights = const [],
    int textOffset = 0,
    TapGestureRecognizer Function(VoidCallback onTap)? tap,
    void Function(WordLink link)? onLink,
    void Function(WordNoteReference note)? onNote,
    Widget Function(WordImage image)? imageBuilder,
    double imageWidth = double.infinity,
  }) {
    final format = paragraph.format;
    final fill = format.fill == null ? null : Color(format.fill!);
    final lineHeight = lineHeightOf(format, firstSizeOf(paragraph));
    final children = <InlineSpan>[];
    final placeholders = <PlaceholderDimensions>[];
    final segments = <(int, int, int, int)>[];
    var laidOut = 0;
    var plain = textOffset;

    void addText(String text, TextStyle style, {GestureRecognizer? recognizer, int? plainLength}) {
      children.add(TextSpan(text: text, style: style, recognizer: recognizer));
      final length = plainLength ?? text.length;
      segments.add((laidOut, plain, text.length, length));
      laidOut += text.length;
      plain += length;
    }

    void addWidget(Widget widget, Size size, int plainLength, PlaceholderAlignment alignment) {
      children.add(WidgetSpan(alignment: alignment, child: widget));
      placeholders.add(PlaceholderDimensions(size: size, alignment: alignment));
      segments.add((laidOut, plain, 1, plainLength));
      laidOut += 1;
      plain += plainLength;
    }

    // Prefixes: an inline marker, or a first-line indent. Not part of the
    // plain text.
    final marker = paragraph.marker;
    if (marker != null && !markerInColumn(paragraph)) {
      final text = marker.text + (marker.suffix == ListMarkerSuffix.space ? ' ' : '');
      children.add(TextSpan(text: text, style: textStyle(marker.format, fill, link: false)));
      segments.add((laidOut, plain, text.length, 0));
      laidOut += text.length;
    } else if (marker == null && format.firstLineIndent > 0 && textOffset == 0) {
      final width = format.firstLineIndent * wordScale;
      children.add(WidgetSpan(child: SizedBox(width: width)));
      placeholders.add(PlaceholderDimensions(size: Size(width, 1), alignment: PlaceholderAlignment.bottom));
      segments.add((laidOut, plain, 1, 0));
      laidOut += 1;
    }

    Color? highlightAt(int start, int end) {
      for (final h in highlights) {
        if (h.start < end && start < h.end) return h.current ? scheme.tertiaryContainer : scheme.secondaryContainer;
      }
      return null;
    }

    final contentStart = children.length;
    for (final inline in paragraph.inlines) {
      switch (inline) {
        case WordText(:final text, :final format, :final link):
          final style = textStyle(format, fill, link: link != null);
          final recognizer = link == null || tap == null || onLink == null ? null : tap(() => onLink(link));
          // Cut where highlights start and end inside this text.
          final cuts = <int>{0, text.length};
          for (final h in highlights) {
            if (h.start > plain && h.start < plain + text.length) cuts.add(h.start - plain);
            if (h.end > plain && h.end < plain + text.length) cuts.add(h.end - plain);
          }
          final points = cuts.toList()..sort();
          for (var i = 0; i + 1 < points.length; i++) {
            final piece = text.substring(points[i], points[i + 1]);
            final mark = highlightAt(plain, plain + piece.length);
            final shown = format.allCaps ? piece.toUpperCase() : piece;
            final pieceStyle = mark == null ? style : style.copyWith(backgroundColor: mark, color: scheme.onSurface);
            if (format.verticalPosition == VerticalTextPosition.baseline) {
              addText(shown, pieceStyle, recognizer: recognizer, plainLength: piece.length);
            } else {
              final superscript = format.verticalPosition == VerticalTextPosition.superscript;
              final small = pieceStyle.copyWith(fontSize: (pieceStyle.fontSize ?? 14) * 0.65);
              addWidget(
                Text(shown, style: small),
                _textSize(shown, small),
                piece.length,
                superscript ? PlaceholderAlignment.top : PlaceholderAlignment.bottom,
              );
            }
          }
        case WordTab(:final format):
          addText('  ', textStyle(format, fill, link: false), plainLength: 1);
        case WordBreak():
          addText('\n', const TextStyle(), plainLength: 1);
        case WordNoteReference(:final label, :final format):
          final style = textStyle(format, fill, link: true);
          final small = style.copyWith(
            fontSize: (style.fontSize ?? 14) * 0.7,
            backgroundColor: highlightAt(plain, plain + label.length),
            decoration: TextDecoration.none,
          );
          final mark = Text(label, style: small);
          addWidget(
            onNote == null
                ? mark
                : Semantics(button: true, label: 'Note $label', child: GestureDetector(onTap: () => onNote(inline), child: mark)),
            _textSize(label, small),
            label.length,
            PlaceholderAlignment.top,
          );
        case WordPageField(:final kind, :final fallback, :final format):
          final number = kind == PageFieldKind.page ? pageNumber : pageCount;
          addText(number?.toString() ?? fallback, textStyle(format, fill, link: false), plainLength: fallback.length);
        case WordImage():
          final size = imageSize(inline, imageWidth);
          addWidget(imageBuilder?.call(inline) ?? SizedBox.fromSize(size: size), size, 0, PlaceholderAlignment.bottom);
        case WordBookmark():
          break;
      }
    }
    // An empty paragraph still takes a line, as in Word.
    if (children.length == contentStart) {
      children.add(const TextSpan(text: ' '));
      segments.add((laidOut, plain, 1, 0));
    }
    return ParagraphSpans(
      // Nothing inherited from the app's text theme (Material's letter
      // spacing, the app font): the widget and the page measurer must lay
      // out exactly the same text.
      TextSpan(
        style: TextStyle(
          inherit: false,
          fontSize: 11 * wordScale,
          height: lineHeight,
          color: scheme.onSurface,
          fontWeight: FontWeight.normal,
          fontStyle: FontStyle.normal,
          letterSpacing: 0,
          wordSpacing: 0,
          textBaseline: TextBaseline.alphabetic,
          decoration: TextDecoration.none,
        ),
        children: children,
      ),
      placeholders,
      segments,
    );
  }

  /// An image's display size, shrunk to [maxWidth].
  static Size imageSize(WordImage image, double maxWidth) {
    var width = image.width * wordScale;
    var height = image.height * wordScale;
    final cap = maxWidth.isFinite ? maxWidth : 400.0;
    if (width <= 0 || height <= 0) (width, height) = (math.min(cap, 200), 120);
    if (width > cap) {
      height *= cap / width;
      width = cap;
    }
    return Size(width, height);
  }

  static Size _textSize(String text, TextStyle style) {
    final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    final size = painter.size;
    painter.dispose();
    return size;
  }

  /// A run's formatting as a [TextStyle]. The file's colours are kept where
  /// they stay readable against what's behind them (fill, highlight, or
  /// the theme surface); otherwise the theme's text colour is used. A link
  /// without its own colour takes the document's hyperlink colour, as in
  /// Word, or the theme's primary where that wouldn't be readable.
  TextStyle textStyle(RunFormat format, Color? paragraphFill, {required bool link}) {
    final runBackground = format.highlight ?? format.fill;
    final behind = runBackground != null ? Color(runBackground) : (paragraphFill ?? scheme.surface);
    final own = format.color != null ? Color(format.color!) : (link ? Color(linkColor) : null);
    Color color;
    if (own != null && contrastRatio(own, behind) >= 3) {
      color = own;
    } else if (link && format.color == null) {
      color = scheme.primary;
    } else if (runBackground != null || paragraphFill != null) {
      color = behind.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    } else {
      color = scheme.onSurface;
    }
    final decorations = [
      if (format.underline != UnderlineStyle.none || link) TextDecoration.underline,
      if (format.strike || format.doubleStrike) TextDecoration.lineThrough,
    ];
    return TextStyle(
      fontSize: format.size * wordScale,
      fontWeight: format.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: format.italic ? FontStyle.italic : FontStyle.normal,
      color: color,
      backgroundColor: runBackground == null ? null : Color(runBackground),
      decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
      decorationStyle: switch (format.underline) {
        UnderlineStyle.double => TextDecorationStyle.double,
        UnderlineStyle.dotted => TextDecorationStyle.dotted,
        UnderlineStyle.dashed => TextDecorationStyle.dashed,
        UnderlineStyle.wavy => TextDecorationStyle.wavy,
        _ => format.doubleStrike ? TextDecorationStyle.double : null,
      },
      decorationColor: color,
      fontFamily: format.font,
      fontFamilyFallback: _fallbackFonts(format.font),
      // Set even when 0, so nothing is inherited from the app's text theme.
      letterSpacing: format.letterSpacing * wordScale,
      wordSpacing: 0,
      fontFeatures: format.smallCaps ? const [FontFeature.enable('smcp')] : null,
    );
  }

  /// When a document's font isn't on the device, a family of the same kind.
  static List<String>? _fallbackFonts(String? font) {
    if (font == null) return null;
    final name = font.toLowerCase();
    const serif = ['times', 'cambria', 'georgia', 'garamond', 'book antiqua', 'palatino', 'serif', 'constantia'];
    const mono = ['courier', 'consolas', 'mono', 'menlo', 'lucida console'];
    if (mono.any(name.contains)) return const ['monospace', 'Courier'];
    if (serif.any(name.contains)) return const ['serif', 'Times New Roman', 'Georgia'];
    return const ['sans-serif', 'Roboto', 'Helvetica'];
  }
}

/// WCAG contrast ratio between two colours (1-21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
