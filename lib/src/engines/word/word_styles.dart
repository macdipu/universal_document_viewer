import 'package:xml/xml.dart';

import 'word_model.dart';

/// WordprocessingML (`w:`) attribute lookup by local name, ignoring the
/// prefix a file happens to use.
String? wAttr(XmlElement? element, String name) {
  if (element == null) return null;
  for (final attribute in element.attributes) {
    if (attribute.localName == name) return attribute.value;
  }
  return null;
}

XmlElement? wChild(XmlElement? element, String name) {
  if (element == null) return null;
  for (final child in element.childElements) {
    if (child.localName == name) return child;
  }
  return null;
}

Iterable<XmlElement> wChildren(XmlElement? element, String name) =>
    element == null ? const [] : element.childElements.where((e) => e.localName == name);

/// `w:val` style on/off switches (§17.17.4): absent or `1/true/on` is on.
bool? wOnOff(XmlElement? element) {
  if (element == null) return null;
  final value = wAttr(element, 'val');
  return value == null || value == '1' || value == 'true' || value == 'on';
}

/// Twentieths of a point -> points. `double.tryParse` also accepts
/// `Infinity` and `NaN`, which no measurement can be: those read as unset.
double? twips(String? value) => switch (double.tryParse(value ?? '')) {
      final v? when v.isFinite => v / 20,
      _ => null,
    };

// --- Theme -----------------------------------------------------------------

/// The theme's fonts and colours (DrawingML, `a:theme`).
class WordTheme {
  const WordTheme({this.majorFont, this.minorFont, this.colors = const {}});

  static const standard = WordTheme(majorFont: 'Calibri Light', minorFont: 'Calibri', colors: {
    'dk1': 0xFF000000, 'lt1': 0xFFFFFFFF, 'dk2': 0xFF44546A, 'lt2': 0xFFE7E6E6, //
    'accent1': 0xFF4472C4, 'accent2': 0xFFED7D31, 'accent3': 0xFFA5A5A5, 'accent4': 0xFFFFC000,
    'accent5': 0xFF5B9BD5, 'accent6': 0xFF70AD47, 'hlink': 0xFF0563C1, 'folHlink': 0xFF954F72,
  });

  final String? majorFont;
  final String? minorFont;

  /// Scheme colour name (`dk1`, `accent1`...) -> 0xAARRGGBB.
  final Map<String, int> colors;

  factory WordTheme.parse(XmlDocument? doc) {
    if (doc == null) return standard;
    XmlElement? find(String name) => doc.descendantElements.where((e) => e.localName == name).firstOrNull;
    String? latin(XmlElement? fontGroup) => wAttr(wChild(fontGroup, 'latin'), 'typeface');
    final scheme = find('clrScheme');
    final colors = <String, int>{...standard.colors};
    for (final entry in scheme?.childElements ?? const <XmlElement>[]) {
      final value = entry.childElements.firstOrNull;
      final hex = switch (value?.localName) {
        'srgbClr' => wAttr(value, 'val'),
        'sysClr' => wAttr(value, 'lastClr'),
        _ => null,
      };
      if (int.tryParse('FF$hex', radix: 16) case final argb? when hex != null) colors[entry.localName] = argb;
    }
    return WordTheme(
      majorFont: latin(find('majorFont')) ?? standard.majorFont,
      minorFont: latin(find('minorFont')) ?? standard.minorFont,
      colors: colors,
    );
  }

  /// `w:themeColor` names -> scheme colour (§17.18.97).
  int? color(String name) {
    const aliases = {
      'text1': 'dk1', 'background1': 'lt1', 'text2': 'dk2', 'background2': 'lt2', //
      'dark1': 'dk1', 'light1': 'lt1', 'dark2': 'dk2', 'light2': 'lt2',
      'hyperlink': 'hlink', 'followedHyperlink': 'folHlink',
    };
    return colors[aliases[name] ?? name];
  }

  /// `asciiTheme` values -> a font name.
  String? font(String name) => name.startsWith('major') ? majorFont : (name.startsWith('minor') ? minorFont : null);
}

// --- Property bags ---------------------------------------------------------

/// Run properties as they accumulate down the style hierarchy; null means
/// "not set at this level".
class RunProps {
  bool? bold;
  bool? italic;
  bool? strike;
  bool? doubleStrike;
  bool? allCaps;
  bool? smallCaps;
  bool? hidden;
  UnderlineStyle? underline;
  int? color;
  int? highlight;
  int? fill;
  double? size;
  String? font;
  VerticalTextPosition? verticalPosition;
  double? letterSpacing;

  RunProps();

  RunProps copy() => RunProps()..overrideWith(this);

  /// Fields set in [other] replace this one's.
  void overrideWith(RunProps other) {
    bold = other.bold ?? bold;
    italic = other.italic ?? italic;
    strike = other.strike ?? strike;
    doubleStrike = other.doubleStrike ?? doubleStrike;
    allCaps = other.allCaps ?? allCaps;
    smallCaps = other.smallCaps ?? smallCaps;
    hidden = other.hidden ?? hidden;
    underline = other.underline ?? underline;
    color = other.color ?? color;
    highlight = other.highlight ?? highlight;
    fill = other.fill ?? fill;
    size = other.size ?? size;
    font = other.font ?? font;
    verticalPosition = other.verticalPosition ?? verticalPosition;
    letterSpacing = other.letterSpacing ?? letterSpacing;
  }

  /// A character style over a paragraph style: toggle properties set at
  /// both levels cancel out (§17.7.3); the rest override.
  void toggleWith(RunProps other) {
    bool? xor(bool? a, bool? b) => a == null ? b : (b == null ? a : a != b);
    final toggled = (
      bold: xor(bold, other.bold),
      italic: xor(italic, other.italic),
      strike: xor(strike, other.strike),
      doubleStrike: xor(doubleStrike, other.doubleStrike),
      allCaps: xor(allCaps, other.allCaps),
      smallCaps: xor(smallCaps, other.smallCaps),
      hidden: xor(hidden, other.hidden),
    );
    overrideWith(other);
    bold = toggled.bold;
    italic = toggled.italic;
    strike = toggled.strike;
    doubleStrike = toggled.doubleStrike;
    allCaps = toggled.allCaps;
    smallCaps = toggled.smallCaps;
    hidden = toggled.hidden;
  }

  /// Reads a `w:rPr`.
  void read(XmlElement? rPr, WordTheme theme) {
    if (rPr == null) return;
    for (final e in rPr.childElements) {
      switch (e.localName) {
        case 'b':
          bold = wOnOff(e);
        case 'i':
          italic = wOnOff(e);
        case 'strike':
          strike = wOnOff(e);
        case 'dstrike':
          doubleStrike = wOnOff(e);
        case 'caps':
          allCaps = wOnOff(e);
        case 'smallCaps':
          smallCaps = wOnOff(e);
        case 'vanish':
          hidden = wOnOff(e);
        case 'u':
          underline = switch (wAttr(e, 'val')) {
            'none' => UnderlineStyle.none,
            'double' => UnderlineStyle.double,
            'dotted' || 'dottedHeavy' => UnderlineStyle.dotted,
            'dash' || 'dashLong' || 'dashedHeavy' || 'dotDash' || 'dotDotDash' => UnderlineStyle.dashed,
            'wave' || 'wavyHeavy' || 'wavyDouble' => UnderlineStyle.wavy,
            _ => UnderlineStyle.single,
          };
        case 'color':
          color = readColor(e, theme) ?? color;
        case 'highlight':
          highlight = _highlightColors[wAttr(e, 'val')];
        case 'shd':
          fill = readShading(e, theme);
        case 'sz':
          if (double.tryParse(wAttr(e, 'val') ?? '') case final halfPoints?) size = halfPoints / 2;
        case 'rFonts':
          final themeFont = wAttr(e, 'asciiTheme') ?? wAttr(e, 'hAnsiTheme');
          font = (themeFont == null ? null : theme.font(themeFont)) ?? wAttr(e, 'ascii') ?? wAttr(e, 'hAnsi') ?? font;
        case 'vertAlign':
          verticalPosition = switch (wAttr(e, 'val')) {
            'superscript' => VerticalTextPosition.superscript,
            'subscript' => VerticalTextPosition.subscript,
            _ => VerticalTextPosition.baseline,
          };
        case 'spacing':
          letterSpacing = twips(wAttr(e, 'val'));
      }
    }
  }

  RunFormat build() => RunFormat(
        bold: bold ?? false,
        italic: italic ?? false,
        underline: underline ?? UnderlineStyle.none,
        strike: strike ?? false,
        doubleStrike: doubleStrike ?? false,
        color: color,
        highlight: highlight,
        fill: fill,
        size: size ?? 11,
        font: font,
        verticalPosition: verticalPosition ?? VerticalTextPosition.baseline,
        allCaps: allCaps ?? false,
        smallCaps: smallCaps ?? false,
        letterSpacing: letterSpacing ?? 0,
      );
}

/// Paragraph properties as they accumulate; null means "not set here".
class ParaProps {
  ParagraphAlignment? alignment;
  double? indentLeft;
  double? indentRight;
  double? firstLineIndent;
  double? spaceBefore;
  double? spaceAfter;
  double? lineSpacing;
  LineSpacingRule? lineSpacingRule;
  int? fill;
  BorderLine? borderTop;
  BorderLine? borderBottom;
  BorderLine? borderLeft;
  BorderLine? borderRight;
  bool? pageBreakBefore;
  bool? keepWithNext;
  bool? rightToLeft;
  int? numId;
  int? numLevel;
  int? outlineLevel;
  String? styleId;

  ParaProps();

  ParaProps copy() => ParaProps()..overrideWith(this);

  void overrideWith(ParaProps other) {
    alignment = other.alignment ?? alignment;
    indentLeft = other.indentLeft ?? indentLeft;
    indentRight = other.indentRight ?? indentRight;
    firstLineIndent = other.firstLineIndent ?? firstLineIndent;
    spaceBefore = other.spaceBefore ?? spaceBefore;
    spaceAfter = other.spaceAfter ?? spaceAfter;
    lineSpacing = other.lineSpacing ?? lineSpacing;
    lineSpacingRule = other.lineSpacingRule ?? lineSpacingRule;
    fill = other.fill ?? fill;
    borderTop = other.borderTop ?? borderTop;
    borderBottom = other.borderBottom ?? borderBottom;
    borderLeft = other.borderLeft ?? borderLeft;
    borderRight = other.borderRight ?? borderRight;
    pageBreakBefore = other.pageBreakBefore ?? pageBreakBefore;
    keepWithNext = other.keepWithNext ?? keepWithNext;
    rightToLeft = other.rightToLeft ?? rightToLeft;
    numId = other.numId ?? numId;
    numLevel = other.numLevel ?? numLevel;
    outlineLevel = other.outlineLevel ?? outlineLevel;
    styleId = other.styleId ?? styleId;
  }

  /// Reads a `w:pPr`.
  void read(XmlElement? pPr, WordTheme theme) {
    if (pPr == null) return;
    for (final e in pPr.childElements) {
      switch (e.localName) {
        case 'pStyle':
          styleId = wAttr(e, 'val');
        case 'jc':
          alignment = switch (wAttr(e, 'val')) {
            'center' => ParagraphAlignment.center,
            'right' || 'end' => ParagraphAlignment.right,
            'both' || 'distribute' || 'lowKashida' || 'mediumKashida' || 'highKashida' => ParagraphAlignment.justify,
            _ => ParagraphAlignment.left,
          };
        case 'ind':
          indentLeft = twips(wAttr(e, 'left') ?? wAttr(e, 'start')) ?? indentLeft;
          indentRight = twips(wAttr(e, 'right') ?? wAttr(e, 'end')) ?? indentRight;
          if (twips(wAttr(e, 'hanging')) case final hanging?) {
            firstLineIndent = -hanging;
          } else if (twips(wAttr(e, 'firstLine')) case final first?) {
            firstLineIndent = first;
          }
        case 'spacing':
          spaceBefore = twips(wAttr(e, 'before')) ?? spaceBefore;
          spaceAfter = twips(wAttr(e, 'after')) ?? spaceAfter;
          if (double.tryParse(wAttr(e, 'line') ?? '') case final line?) {
            switch (wAttr(e, 'lineRule')) {
              case 'exact':
                lineSpacingRule = LineSpacingRule.exact;
                lineSpacing = line / 20;
              case 'atLeast':
                lineSpacingRule = LineSpacingRule.atLeast;
                lineSpacing = line / 20;
              default:
                lineSpacingRule = LineSpacingRule.auto;
                lineSpacing = line / 240;
            }
          }
        case 'shd':
          fill = readShading(e, theme);
        case 'pBdr':
          borderTop = readBorder(wChild(e, 'top'), theme) ?? borderTop;
          borderBottom = readBorder(wChild(e, 'bottom'), theme) ?? borderBottom;
          borderLeft = readBorder(wChild(e, 'left') ?? wChild(e, 'start'), theme) ?? borderLeft;
          borderRight = readBorder(wChild(e, 'right') ?? wChild(e, 'end'), theme) ?? borderRight;
        case 'pageBreakBefore':
          pageBreakBefore = wOnOff(e);
        case 'keepNext':
          keepWithNext = wOnOff(e);
        case 'bidi':
          rightToLeft = wOnOff(e);
        case 'outlineLvl':
          outlineLevel = int.tryParse(wAttr(e, 'val') ?? '');
        case 'numPr':
          numId = int.tryParse(wAttr(wChild(e, 'numId'), 'val') ?? '') ?? numId;
          numLevel = int.tryParse(wAttr(wChild(e, 'ilvl'), 'val') ?? '') ?? numLevel;
      }
    }
  }

  ParagraphFormat build() => ParagraphFormat(
        alignment: alignment ?? ParagraphAlignment.left,
        indentLeft: indentLeft ?? 0,
        indentRight: indentRight ?? 0,
        firstLineIndent: firstLineIndent ?? 0,
        spaceBefore: spaceBefore ?? 0,
        spaceAfter: spaceAfter ?? 0,
        lineSpacing: lineSpacing ?? 1,
        lineSpacingRule: lineSpacingRule ?? LineSpacingRule.auto,
        fill: fill,
        borderTop: borderTop,
        borderBottom: borderBottom,
        borderLeft: borderLeft,
        borderRight: borderRight,
        pageBreakBefore: pageBreakBefore ?? false,
        keepWithNext: keepWithNext ?? false,
        rightToLeft: rightToLeft ?? false,
      );
}

// --- Colours ---------------------------------------------------------------

/// A `w:color`: `val` (hex or `auto`), or `themeColor` with optional
/// `themeTint`/`themeShade` (hex 00-FF).
int? readColor(XmlElement element, WordTheme theme) {
  final themeName = wAttr(element, 'themeColor');
  int? base = themeName == null ? null : theme.color(themeName);
  if (base == null) {
    final value = wAttr(element, 'val');
    if (value == null || value == 'auto') return null;
    base = int.tryParse('FF$value', radix: 16);
    if (base == null) return null;
  }
  if (int.tryParse(wAttr(element, 'themeTint') ?? '', radix: 16) case final tint?) {
    base = _scaleLuminance(base, tint / 255, lighten: true);
  } else if (int.tryParse(wAttr(element, 'themeShade') ?? '', radix: 16) case final shade?) {
    base = _scaleLuminance(base, shade / 255, lighten: false);
  }
  return base;
}

/// `w:shd`: the fill colour (`fill`, or a theme fill); patterns aren't drawn.
int? readShading(XmlElement element, WordTheme theme) {
  final themeFill = wAttr(element, 'themeFill');
  if (themeFill != null) return theme.color(themeFill);
  final fill = wAttr(element, 'fill');
  if (fill == null || fill == 'auto') return null;
  return int.tryParse('FF$fill', radix: 16);
}

/// A `w:top`/`w:bottom`... border; `none`/`nil` mean no line.
BorderLine? readBorder(XmlElement? element, WordTheme theme) {
  if (element == null) return null;
  final style = wAttr(element, 'val');
  if (style == null || style == 'none' || style == 'nil') return const BorderLine(width: 0);
  final eighths = double.tryParse(wAttr(element, 'sz') ?? '') ?? 4;
  return BorderLine(width: eighths / 8, color: readColor(element, theme));
}

/// Theme tint (towards white) or shade (towards black) in HSL lightness.
int _scaleLuminance(int argb, double factor, {required bool lighten}) {
  final r = ((argb >> 16) & 0xFF) / 255;
  final g = ((argb >> 8) & 0xFF) / 255;
  final b = (argb & 0xFF) / 255;
  final max = [r, g, b].reduce((a, c) => a > c ? a : c);
  final min = [r, g, b].reduce((a, c) => a < c ? a : c);
  var l = (max + min) / 2;
  double h = 0;
  double s = 0;
  if (max != min) {
    final d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    h = max == r ? ((g - b) / d) % 6 : (max == g ? (b - r) / d + 2 : (r - g) / d + 4);
    h /= 6;
  }
  l = lighten ? l * factor + (1 - factor) : l * factor;
  double channel(double t) {
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    var tt = t;
    if (tt < 0) tt += 1;
    if (tt > 1) tt -= 1;
    if (tt < 1 / 6) return p + (q - p) * 6 * tt;
    if (tt < 1 / 2) return q;
    if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
    return p;
  }

  final (nr, ng, nb) = s == 0 ? (l, l, l) : (channel(h + 1 / 3), channel(h), channel(h - 1 / 3));
  int byte(double v) => (v * 255).round().clamp(0, 255);
  return 0xFF000000 | (byte(nr) << 16) | (byte(ng) << 8) | byte(nb);
}

/// `w:highlight` names (§17.18.40).
const _highlightColors = <String, int>{
  'yellow': 0xFFFFFF00, 'green': 0xFF00FF00, 'cyan': 0xFF00FFFF, 'magenta': 0xFFFF00FF, //
  'blue': 0xFF0000FF, 'red': 0xFFFF0000, 'darkBlue': 0xFF000080, 'darkCyan': 0xFF008080,
  'darkGreen': 0xFF008000, 'darkMagenta': 0xFF800080, 'darkRed': 0xFF800000, 'darkYellow': 0xFF808000,
  'darkGray': 0xFF808080, 'lightGray': 0xFFC0C0C0, 'black': 0xFF000000, 'white': 0xFFFFFFFF,
};

// --- Style sheet -----------------------------------------------------------

/// A table style's parts this reader uses: its whole-table borders and
/// cell text formatting, and conditional formats for header/total rows,
/// first/last columns and banding.
class TableStyle {
  TableStyle();

  final run = RunProps();
  final paragraph = ParaProps();
  CellBorders borders = CellBorders.none;
  BorderLine? insideHorizontal;
  BorderLine? insideVertical;
  final conditional = <String, ({RunProps run, int? fill})>{};
}

/// `styles.xml` with resolution: [paragraphStyle], [characterStyle] and
/// [tableStyle] walk each style's `basedOn` chain once (cycle-safe) and
/// memoise the result.
class WordStyles {
  WordStyles._(this.theme, this._styles, this._defaultParagraphStyle, this.defaultRun, this.defaultParagraph);

  final WordTheme theme;
  final Map<String, XmlElement> _styles;
  final String? _defaultParagraphStyle;

  /// `w:docDefaults`.
  final RunProps defaultRun;
  final ParaProps defaultParagraph;

  final _paragraphCache = <String?, (ParaProps, RunProps)>{};
  final _characterCache = <String, RunProps>{};
  final _tableCache = <String, TableStyle>{};

  factory WordStyles.parse(XmlDocument? doc, WordTheme theme) {
    final root = doc?.rootElement;
    final styles = <String, XmlElement>{};
    String? defaultParagraph;
    for (final style in wChildren(root, 'style')) {
      final id = wAttr(style, 'styleId');
      if (id == null) continue;
      styles[id] = style;
      final isDefault = switch (wAttr(style, 'default')) { '1' || 'true' || 'on' => true, _ => false };
      if (isDefault && wAttr(style, 'type') == 'paragraph') defaultParagraph ??= id;
    }
    final defaults = wChild(root, 'docDefaults');
    final run = RunProps()..read(wChild(wChild(defaults, 'rPrDefault'), 'rPr'), theme);
    final paragraph = ParaProps()..read(wChild(wChild(defaults, 'pPrDefault'), 'pPr'), theme);
    return WordStyles._(theme, styles, defaultParagraph ?? (styles.containsKey('Normal') ? 'Normal' : null), run,
        paragraph);
  }

  /// The chain from [id] up through `basedOn`, root first.
  List<XmlElement> _chain(String id) {
    final chain = <XmlElement>[];
    final seen = <String>{};
    String? current = id;
    while (current != null && seen.add(current)) {
      final style = _styles[current];
      if (style == null) break;
      chain.add(style);
      current = wAttr(wChild(style, 'basedOn'), 'val');
    }
    return chain.reversed.toList();
  }

  /// A paragraph style's paragraph and run properties (not including
  /// docDefaults); [id] null or unknown means the default paragraph style.
  (ParaProps, RunProps) paragraphStyle(String? id) {
    final key = id != null && _styles.containsKey(id) ? id : _defaultParagraphStyle;
    return _paragraphCache.putIfAbsent(key, () {
      final paragraph = ParaProps();
      final run = RunProps();
      if (key != null) {
        for (final style in _chain(key)) {
          paragraph.overrideWith(ParaProps()..read(wChild(style, 'pPr'), theme));
          run.overrideWith(RunProps()..read(wChild(style, 'rPr'), theme));
        }
      }
      // A style's own pStyle reference isn't the paragraph's.
      paragraph.styleId = key;
      return (paragraph, run);
    });
  }

  /// A character style's run properties; empty for none or unknown ids
  /// (falling back to a paragraph style here would be wrong).
  RunProps characterStyle(String? id) {
    if (id == null || !_styles.containsKey(id)) return RunProps();
    return _characterCache.putIfAbsent(id, () {
      final run = RunProps();
      for (final style in _chain(id)) {
        run.overrideWith(RunProps()..read(wChild(style, 'rPr'), theme));
      }
      return run;
    });
  }

  TableStyle tableStyle(String? id) {
    if (id == null || !_styles.containsKey(id)) return TableStyle();
    return _tableCache.putIfAbsent(id, () {
      final table = TableStyle();
      for (final style in _chain(id)) {
        table.run.overrideWith(RunProps()..read(wChild(style, 'rPr'), theme));
        table.paragraph.overrideWith(ParaProps()..read(wChild(style, 'pPr'), theme));
        final borders = wChild(wChild(style, 'tblPr'), 'tblBorders');
        if (borders != null) {
          table.borders = CellBorders(
            top: readBorder(wChild(borders, 'top'), theme) ?? table.borders.top,
            bottom: readBorder(wChild(borders, 'bottom'), theme) ?? table.borders.bottom,
            left: readBorder(wChild(borders, 'left') ?? wChild(borders, 'start'), theme) ?? table.borders.left,
            right: readBorder(wChild(borders, 'right') ?? wChild(borders, 'end'), theme) ?? table.borders.right,
          );
          table.insideHorizontal = readBorder(wChild(borders, 'insideH'), theme) ?? table.insideHorizontal;
          table.insideVertical = readBorder(wChild(borders, 'insideV'), theme) ?? table.insideVertical;
        }
        for (final conditional in wChildren(style, 'tblStylePr')) {
          final type = wAttr(conditional, 'type');
          if (type == null) continue;
          final run = (table.conditional[type]?.run.copy() ?? RunProps())..read(wChild(conditional, 'rPr'), theme);
          final shading = wChild(wChild(conditional, 'tcPr'), 'shd');
          table.conditional[type] = (
            run: run,
            fill: shading == null ? table.conditional[type]?.fill : readShading(shading, theme),
          );
        }
      }
      return table;
    });
  }
}

// --- Numbering ---------------------------------------------------------------

class _Level {
  _Level({
    required this.start,
    required this.format,
    required this.text,
    required this.paragraph,
    required this.run,
    required this.suffix,
    required this.restartAfter,
  });

  final int start;
  final String format;
  final String text;
  final ParaProps paragraph;
  final RunProps run;
  final ListMarkerSuffix suffix;

  /// Restart after a use of this (0-based) level or any above it; -1 never.
  final int restartAfter;
}

/// `numbering.xml`, plus the running counters that turn each list
/// paragraph into its number.
///
/// Counters belong to the abstract list definition, so separate `w:num`s
/// that share one continue each other's numbering, as in Word; a `w:num`
/// with a `startOverride` restarts that level the first time it's used.
class WordNumbering {
  WordNumbering._(this._abstract, this._nums, this._overrides);

  final Map<int, Map<int, _Level>> _abstract;

  /// numId -> abstractNumId.
  final Map<int, int> _nums;

  /// numId -> level -> start override.
  final Map<int, Map<int, int>> _overrides;

  final _counters = <int, List<int?>>{};
  final _overridesApplied = <int>{};

  factory WordNumbering.parse(XmlDocument? doc, WordTheme theme) {
    final root = doc?.rootElement;
    final abstract = <int, Map<int, _Level>>{};
    // Lists have nine levels (0-8); the counters are sized to match, so a
    // level outside them is dropped here rather than indexed later.
    bool isLevel(int? level) => level != null && level >= 0 && level < _levels;
    for (final definition in wChildren(root, 'abstractNum')) {
      final id = int.tryParse(wAttr(definition, 'abstractNumId') ?? '');
      if (id == null) continue;
      abstract[id] = {
        for (final level in wChildren(definition, 'lvl'))
          if (int.tryParse(wAttr(level, 'ilvl') ?? '') case final ilvl? when isLevel(ilvl))
            ilvl: _readLevel(level, ilvl, theme),
      };
    }
    final nums = <int, int>{};
    final overrides = <int, Map<int, int>>{};
    for (final num in wChildren(root, 'num')) {
      final id = int.tryParse(wAttr(num, 'numId') ?? '');
      final abstractId = int.tryParse(wAttr(wChild(num, 'abstractNumId'), 'val') ?? '');
      if (id == null || abstractId == null) continue;
      nums[id] = abstractId;
      for (final override in wChildren(num, 'lvlOverride')) {
        final level = int.tryParse(wAttr(override, 'ilvl') ?? '');
        final start = int.tryParse(wAttr(wChild(override, 'startOverride'), 'val') ?? '');
        if (isLevel(level) && start != null) (overrides[id] ??= {})[level!] = _clampNumber(start);
      }
    }
    return WordNumbering._(abstract, nums, overrides);
  }

  /// List levels per definition (§17.9.6).
  static const _levels = 9;

  /// Word keeps list numbers to 0-32767. Bounding them also bounds letter
  /// numbering, which repeats the letter once per 26 (`aaa...`).
  static const _maxNumber = 32767;
  static int _clampNumber(int value) => value.clamp(0, _maxNumber);

  static _Level _readLevel(XmlElement level, int ilvl, WordTheme theme) => _Level(
        start: _clampNumber(int.tryParse(wAttr(wChild(level, 'start'), 'val') ?? '') ?? 1),
        format: wAttr(wChild(level, 'numFmt'), 'val') ?? 'decimal',
        text: wAttr(wChild(level, 'lvlText'), 'val') ?? '',
        paragraph: ParaProps()..read(wChild(level, 'pPr'), theme),
        run: RunProps()..read(wChild(level, 'rPr'), theme),
        suffix: switch (wAttr(wChild(level, 'suff'), 'val')) {
          'space' => ListMarkerSuffix.space,
          'nothing' => ListMarkerSuffix.nothing,
          _ => ListMarkerSuffix.tab,
        },
        restartAfter: switch (int.tryParse(wAttr(wChild(level, 'lvlRestart'), 'val') ?? '')) {
          0 => -1,
          final v? => v - 1,
          null => ilvl - 1,
        },
      );

  _Level? _level(int numId, int level) => _abstract[_nums[numId]]?[level];

  /// The level's indents, applied between the paragraph style and the
  /// paragraph's own formatting.
  ParaProps? levelParagraph(int numId, int level) => _level(numId, level)?.paragraph;

  /// Advances the counters for one list paragraph and returns its marker
  /// (null for numId 0, "no numbering", or an unknown list).
  ListMarker? next(int numId, int level, RunProps paragraphRun) {
    final abstractId = _nums[numId];
    final definition = abstractId == null ? null : _abstract[abstractId];
    final current = definition?[level];
    if (abstractId == null || definition == null || current == null) return null;
    final counters = _counters.putIfAbsent(abstractId, () => List<int?>.filled(_levels, null));
    if (_overrides[numId] case final overrides? when _overridesApplied.add(numId)) {
      overrides.forEach((l, start) => counters[l] = start - 1);
    }
    counters[level] = _clampNumber((counters[level] ?? (current.start - 1)) + 1);
    for (var deeper = level + 1; deeper < _levels; deeper++) {
      final restartAfter = definition[deeper]?.restartAfter ?? deeper - 1;
      if (restartAfter >= level) counters[deeper] = null;
    }
    // `%1`-`%9` stand for the levels' numbers; `%0` names no level, so shows
    // nothing.
    final text = current.text.replaceAllMapped(RegExp(r'%(\d)'), (m) {
      final l = int.parse(m.group(1)!) - 1;
      if (l < 0) return '';
      final levelDefinition = definition[l];
      final value = counters[l] ?? levelDefinition?.start ?? 1;
      // A higher level shown in a lower one's number ("1.1") uses decimal
      // when the lower level asks for legal numbering; plain otherwise.
      return formatNumber(value, levelDefinition?.format ?? 'decimal');
    });
    final run = paragraphRun.copy()..overrideWith(current.run);
    return ListMarker(
      current.format == 'bullet' ? _bulletGlyph(text, current.run.font) : text,
      format: run.build(),
      level: level,
      suffix: current.suffix,
    );
  }

  /// A number in a list format (§17.18.59).
  static String formatNumber(int value, String format) => switch (format) {
        'lowerLetter' => _letters(value).toLowerCase(),
        'upperLetter' => _letters(value),
        'lowerRoman' => _roman(value).toLowerCase(),
        'upperRoman' => _roman(value),
        'decimalZero' => value.toString().padLeft(2, '0'),
        'ordinal' => '$value${_ordinalSuffix(value)}',
        'none' => '',
        'bullet' => '',
        _ => '$value',
      };

  static String _letters(int value) {
    if (value <= 0) return '';
    // Word repeats the letter: a..z, aa..zz, aaa...
    final letter = String.fromCharCode(0x41 + (value - 1) % 26);
    return letter * ((value - 1) ~/ 26 + 1);
  }

  static String _roman(int value) {
    if (value <= 0 || value >= 4000) return '$value';
    const numerals = [
      (1000, 'M'), (900, 'CM'), (500, 'D'), (400, 'CD'), (100, 'C'), (90, 'XC'), //
      (50, 'L'), (40, 'XL'), (10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I'),
    ];
    final out = StringBuffer();
    var rest = value;
    for (final (amount, numeral) in numerals) {
      while (rest >= amount) {
        out.write(numeral);
        rest -= amount;
      }
    }
    return out.toString();
  }

  static String _ordinalSuffix(int value) {
    if (value % 100 >= 11 && value % 100 <= 13) return 'th';
    return switch (value % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
  }

  /// Symbol-font bullets are Private Use Area characters that mean nothing
  /// in other fonts; show the bullet they stand for.
  static String _bulletGlyph(String text, String? font) {
    if (text.isEmpty) return '•';
    final code = text.codeUnitAt(0);
    final symbolFont = font != null && (font.contains('Symbol') || font.contains('Wingdings'));
    if (code >= 0xF000 && code <= 0xF0FF || symbolFont) {
      return switch (code & 0xFF) {
        0xB7 || 0x9F || 0x6C => '•',
        0xA7 || 0x6E => '▪',
        0x6F => '○',
        0xD8 => '➢',
        0xFC => '✓',
        0x76 => '❖',
        _ => '•',
      };
    }
    return text;
  }
}
