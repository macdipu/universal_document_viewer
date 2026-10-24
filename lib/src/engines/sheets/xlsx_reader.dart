import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../ooxml/opc_package.dart';
import 'conditional_formatting.dart';
import 'formula_references.dart';
import 'number_format.dart';
import 'workbook.dart';

/// The file isn't a readable `.xlsx`.
class XlsxFormatException implements Exception {
  const XlsxFormatException(this.message);
  final String message;

  @override
  String toString() => 'XlsxFormatException: $message';
}

/// Reads an `.xlsx` workbook (SpreadsheetML, ECMA-376 Part 1 §18) for
/// display: sheet order and visibility, cell values (shared and inline
/// strings, numbers, booleans, errors, formulas with their saved results),
/// the formatting a reader shows (number format, bold, italic, solid fill
/// with theme and indexed colours, cell borders), conditional formatting
/// (see [ConditionalRule] for which rules), comments, and frozen panes.
///
/// Sheets are streamed (XML events, not a document tree), so a large sheet
/// doesn't hold its whole XML tree in memory. Callers should check the
/// bytes with `ZipSafetyGuard` first, and can run this in a background
/// isolate: the [Workbook] it returns is plain data.
abstract final class XlsxReader {
  static Workbook read(Uint8List bytes) {
    try {
      return _read(OpcPackage.decode(bytes));
    } on OpcFormatException catch (e) {
      throw XlsxFormatException(e.message);
    } on XmlException {
      throw const XlsxFormatException('Malformed XML');
    }
  }

  static Workbook _read(OpcPackage package) {
    final workbookPath = package.mainPart ?? 'xl/workbook.xml';
    final workbook = package.readXml(workbookPath);
    if (workbook == null) throw const XlsxFormatException('No workbook part');
    final rels = package.relationshipsOf(workbookPath);
    String? partOfType(String kind) => rels.where((r) => !r.external && r.isOfType(kind)).firstOrNull?.target;
    String? textOfType(String kind) => switch (partOfType(kind)) {
          final path? => package.readText(path),
          null => null,
        };

    final date1904 = switch (_child(workbook.rootElement, 'workbookPr')?.getAttribute('date1904')) {
      '1' || 'true' => true,
      _ => false,
    };
    final sharedStrings = _sharedStrings(textOfType('sharedStrings'));
    final theme = _themeColors(package, partOfType('theme'));
    final (:styles, :differential) = _styles(package, partOfType('styles'), theme);

    final sheets = <Worksheet>[];
    final sheetsElement = _child(workbook.rootElement, 'sheets');
    for (final sheet in sheetsElement?.childElements.where((e) => e.localName == 'sheet') ?? const <XmlElement>[]) {
      final name = sheet.getAttribute('name') ?? 'Sheet${sheets.length + 1}';
      final id = sheet.attributes.where((a) => a.localName == 'id').firstOrNull?.value;
      final target = rels.where((r) => r.id == id && !r.external).firstOrNull?.target;
      final visibility = switch (sheet.getAttribute('state')) {
        'hidden' => SheetVisibility.hidden,
        'veryHidden' => SheetVisibility.veryHidden,
        _ => SheetVisibility.visible,
      };
      final xml = target == null ? null : package.readText(target);
      final sheetRels = target == null ? const <OpcRelationship>[] : package.relationshipsOf(target);
      // A chart sheet or a missing part: an empty sheet keeps tabs in step.
      sheets.add(xml == null
          ? Worksheet(name: name, rows: const [], visibility: visibility)
          : _worksheet(
              xml,
              name: name,
              visibility: visibility,
              sharedStrings: sharedStrings,
              styles: styles,
              differential: differential,
              theme: theme,
              date1904: date1904,
              links: {
                for (final rel in sheetRels)
                  if (rel.isOfType('hyperlink')) rel.id: rel.target,
              },
              comments: _comments(package, sheetRels.where((r) => !r.external && r.isOfType('comments')).firstOrNull?.target),
            ));
    }
    return Workbook(sheets, date1904: date1904);
  }

  static XmlElement? _child(XmlElement parent, String localName) =>
      parent.childElements.where((e) => e.localName == localName).firstOrNull;

  // --- Shared strings (§18.4) ------------------------------------------------

  /// Each `<si>`'s text: its `<t>`, or its rich-text runs' `<t>`s joined.
  /// Phonetic guides (`<rPh>`) aren't part of the text.
  static List<String> _sharedStrings(String? source) {
    if (source == null) return const [];
    final strings = <String>[];
    final current = StringBuffer();
    var inItem = false;
    var inText = false;
    var phoneticDepth = 0;
    for (final event in _events(source)) {
      switch (event) {
        case XmlStartElementEvent(:final localName, :final isSelfClosing):
          if (localName == 'si') {
            inItem = true;
            current.clear();
            if (isSelfClosing) {
              strings.add('');
              inItem = false;
            }
          } else if (localName == 'rPh' && !isSelfClosing) {
            phoneticDepth++;
          } else if (localName == 't' && inItem && phoneticDepth == 0 && !isSelfClosing) {
            inText = true;
          }
        case XmlEndElementEvent(:final localName):
          if (localName == 'si') {
            strings.add(_unescapeOoxml(current.toString()));
            inItem = false;
          } else if (localName == 'rPh') {
            phoneticDepth--;
          } else if (localName == 't') {
            inText = false;
          }
        case XmlTextEvent(:final value) when inText:
          current.write(value);
        case XmlCDATAEvent(:final value) when inText:
          current.write(value);
        default:
          break;
      }
    }
    return strings;
  }

  /// `_x000D_`-style escapes (§22.4.2.4) for characters XML can't carry.
  static String _unescapeOoxml(String text) {
    if (!text.contains('_x')) return text;
    return text.replaceAllMapped(
      RegExp('_x([0-9A-Fa-f]{4})_'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
  }

  /// Lazy: malformed XML throws while iterating, which [read] turns into
  /// an [XlsxFormatException].
  static Iterable<XmlEvent> _events(String source) => parseEvents(source);

  // --- Theme and styles (§18.8, DrawingML §20.1.6) ---------------------------

  /// The theme's colour scheme as 0xAARRGGBB, in the order cell styles
  /// index it: lt1, dk1, lt2, dk2, accent1-6, hlink, folHlink. (The file
  /// stores dk1 before lt1; spreadsheet theme indices swap each pair.)
  static List<int> _themeColors(OpcPackage package, String? part) {
    final doc = part == null ? null : package.readXml(part);
    if (doc == null) return _defaultTheme;
    final scheme = doc.descendantElements.where((e) => e.localName == 'clrScheme').firstOrNull;
    if (scheme == null) return _defaultTheme;
    int? colorOf(String name) {
      final element = _child(scheme, name);
      final value = element?.childElements.firstOrNull;
      final hex = switch (value?.localName) {
        'srgbClr' => value!.getAttribute('val'),
        'sysClr' => value!.getAttribute('lastClr'),
        _ => null,
      };
      return hex == null ? null : int.tryParse('FF$hex', radix: 16);
    }

    const order = ['lt1', 'dk1', 'lt2', 'dk2', 'accent1', 'accent2', 'accent3', 'accent4', 'accent5', 'accent6', 'hlink', 'folHlink'];
    return [for (var i = 0; i < order.length; i++) colorOf(order[i]) ?? _defaultTheme[i]];
  }

  /// Office's default theme, for files without one.
  static const _defaultTheme = [
    0xFFFFFFFF, 0xFF000000, 0xFFE7E6E6, 0xFF44546A, 0xFF4472C4, 0xFFED7D31, //
    0xFFA5A5A5, 0xFFFFC000, 0xFF5B9BD5, 0xFF70AD47, 0xFF0563C1, 0xFF954F72,
  ];

  /// Cell formats (`<cellXfs>`), by the index cells use in their `s`, and
  /// conditional formats' looks (`<dxfs>`), by a rule's `dxfId`.
  static ({List<CellStyle> styles, List<DifferentialStyle> differential}) _styles(
    OpcPackage package,
    String? part,
    List<int> theme,
  ) {
    final root = part == null ? null : package.readXml(part)?.rootElement;
    if (root == null) return (styles: const [], differential: const []);

    final customFormats = <int, String>{
      for (final f in _child(root, 'numFmts')?.childElements ?? const <XmlElement>[])
        if (int.tryParse(f.getAttribute('numFmtId') ?? '') case final id?) id: f.getAttribute('formatCode') ?? 'General',
    };

    final fonts = [
      for (final font in _child(root, 'fonts')?.childElements ?? const <XmlElement>[])
        (
          bold: _flag(_child(font, 'b')),
          italic: _flag(_child(font, 'i')),
          underline: switch (_child(font, 'u')) {
            null => false,
            final u => u.getAttribute('val') != 'none',
          },
          strikethrough: _flag(_child(font, 'strike')),
          size: double.tryParse(_child(font, 'sz')?.getAttribute('val') ?? ''),
          color: switch (_child(font, 'color')) {
            final c? => _color(c, theme),
            null => null,
          },
        ),
    ];

    final fills = [
      for (final fill in _child(root, 'fills')?.childElements ?? const <XmlElement>[]) _fillColor(fill, theme),
    ];

    final borders = [
      for (final border in _child(root, 'borders')?.childElements ?? const <XmlElement>[]) _borders(border, theme),
    ];

    final styles = [
      for (final xf in _child(root, 'cellXfs')?.childElements ?? const <XmlElement>[])
        () {
          final numFmtId = int.tryParse(xf.getAttribute('numFmtId') ?? '') ?? 0;
          final fontId = int.tryParse(xf.getAttribute('fontId') ?? '') ?? 0;
          final fillId = int.tryParse(xf.getAttribute('fillId') ?? '') ?? 0;
          final borderId = int.tryParse(xf.getAttribute('borderId') ?? '') ?? 0;
          final font = fontId < fonts.length ? fonts[fontId] : null;
          final format = customFormats[numFmtId] != null
              ? NumberFormat(customFormats[numFmtId]!)
              : NumberFormat.builtIn(numFmtId) ?? NumberFormat.general;
          final alignment = _child(xf, 'alignment');
          return CellStyle(
            bold: font?.bold ?? false,
            italic: font?.italic ?? false,
            underline: font?.underline ?? false,
            strikethrough: font?.strikethrough ?? false,
            fontSize: font?.size,
            // Black is the automatic colour; leave it to the theme.
            textColor: font?.color == 0xFF000000 ? null : font?.color,
            fillColor: fillId < fills.length ? fills[fillId] : null,
            horizontalAlignment: HorizontalAlignment.values.asNameMap()[alignment?.getAttribute('horizontal')] ??
                HorizontalAlignment.general,
            verticalAlignment:
                VerticalAlignment.values.asNameMap()[alignment?.getAttribute('vertical')] ?? VerticalAlignment.bottom,
            wrapText: _flag(alignment, attribute: 'wrapText', absent: false),
            numberFormat: format,
            borders: borderId < borders.length ? borders[borderId] : CellBorders.none,
          );
        }(),
    ];

    final differential = [
      for (final dxf in _child(root, 'dxfs')?.childElements ?? const <XmlElement>[]) _differentialStyle(dxf, theme),
    ];
    return (styles: styles, differential: differential);
  }

  /// A `<border>`'s four sides (§18.8.4); diagonals aren't drawn.
  static CellBorders _borders(XmlElement border, List<int> theme) {
    BorderLine? side(String name) {
      final element = _child(border, name) ?? (name == 'left' ? _child(border, 'start') : null) ??
          (name == 'right' ? _child(border, 'end') : null);
      final style = BorderLineStyle.values.asNameMap()[switch (element?.getAttribute('style')) {
        'double' => 'doubleLine',
        final other => other,
      }];
      if (style == null) return null;
      final color = switch (_child(element!, 'color')) {
        final c? when c.getAttribute('auto') != '1' && c.getAttribute('auto') != 'true' => _color(c, theme),
        _ => null,
      };
      return BorderLine(style, color: color);
    }

    final borders = CellBorders(left: side('left'), right: side('right'), top: side('top'), bottom: side('bottom'));
    return borders.isEmpty ? CellBorders.none : borders;
  }

  /// A `<dxf>`: the font and fill a conditional format sets. Its solid
  /// fill's colour is `bgColor` (§18.8.17), though some writers use
  /// `fgColor`.
  static DifferentialStyle _differentialStyle(XmlElement dxf, List<int> theme) {
    final font = _child(dxf, 'font');
    bool? flag(String name) => switch (font == null ? null : _child(font, name)) {
          null => null,
          final element => _flag(element),
        };
    final pattern = switch (_child(dxf, 'fill')) {
      final fill? => _child(fill, 'patternFill'),
      null => null,
    };
    final fillColorElement = pattern == null ? null : (_child(pattern, 'bgColor') ?? _child(pattern, 'fgColor'));
    final patternType = pattern?.getAttribute('patternType');
    return DifferentialStyle(
      bold: flag('b'),
      italic: flag('i'),
      underline: switch (font == null ? null : _child(font, 'u')) {
        null => null,
        final u => u.getAttribute('val') != 'none',
      },
      strikethrough: flag('strike'),
      textColor: switch (font == null ? null : _child(font, 'color')) {
        final c? => _color(c, theme),
        null => null,
      },
      fillColor: fillColorElement == null || (patternType != null && patternType != 'solid')
          ? null
          : _color(fillColorElement, theme),
    );
  }

  /// A sheet's comments part (§18.7): each `<comment>`'s text and author.
  /// A threaded comment's fallback text loses Excel's notice about
  /// threaded comments.
  static Map<CellAddress, CellComment> _comments(OpcPackage package, String? part) {
    final root = part == null ? null : package.readXml(part)?.rootElement;
    if (root == null) return const {};
    final authors = [
      for (final author in _child(root, 'authors')?.childElements ?? const <XmlElement>[]) author.innerText,
    ];
    final comments = <CellAddress, CellComment>{};
    for (final comment in _child(root, 'commentList')?.childElements ?? const <XmlElement>[]) {
      final range = _range(comment.getAttribute('ref'));
      final body = _child(comment, 'text');
      if (range == null || body == null) continue;
      final text = StringBuffer();
      for (final t in body.descendantElements) {
        // Phonetic guides aren't part of the text.
        if (t.localName == 't' && t.parentElement?.localName != 'rPh') text.write(t.innerText);
      }
      final authorId = int.tryParse(comment.getAttribute('authorId') ?? '');
      final author = authorId != null && authorId >= 0 && authorId < authors.length ? authors[authorId] : null;
      comments[(row: range.firstRow, column: range.firstColumn)] = CellComment(
        _threadedText(_unescapeOoxml(text.toString())),
        author: author == null || author.isEmpty || author.startsWith('tc=') ? null : author,
      );
    }
    return comments;
  }

  /// Excel writes a threaded comment's legacy copy as a notice, then
  /// `Comment:` and the thread; keep the thread.
  static String _threadedText(String text) {
    if (!text.startsWith('[Threaded comment]')) return text.trim();
    final at = text.indexOf('Comment:');
    if (at < 0) return text.trim();
    return text.substring(at + 'Comment:'.length).split('\n').map((line) => line.trim()).join('\n').trim();
  }

  /// `<b/>` and `<b val="1"/>` are on; `<b val="0"/>` and no element off.
  /// With [attribute], reads that boolean attribute instead (missing means
  /// [absent]).
  static bool _flag(XmlElement? element, {String attribute = 'val', bool absent = true}) {
    if (element == null) return false;
    final value = element.getAttribute(attribute);
    return value == null ? absent : value == '1' || value == 'true';
  }

  /// A solid pattern fill's colour (`fgColor`). Other patterns (hatching)
  /// and gradients aren't drawn.
  static int? _fillColor(XmlElement fill, List<int> theme) {
    final pattern = _child(fill, 'patternFill');
    if (pattern == null || pattern.getAttribute('patternType') != 'solid') return null;
    final color = _child(pattern, 'fgColor');
    return color == null ? null : _color(color, theme);
  }

  /// A `CT_Color` (§18.8.19): `rgb`, `theme` (+ `tint`) or `indexed`.
  static int? _color(XmlElement color, List<int> theme) => _colorOf(color.getAttribute, theme);

  /// [_color] from a colour element's attributes, for streamed XML.
  static int? _colorOf(String? Function(String name) attribute, List<int> theme) {
    final color = (getAttribute: attribute);
    int? base;
    if (color.getAttribute('rgb') case final rgb?) {
      final hex = rgb.length == 6 ? 'FF$rgb' : rgb;
      base = int.tryParse(hex, radix: 16);
      // Alpha 00 is common in files and still means opaque in practice.
      if (base != null && (base >> 24) == 0) base |= 0xFF000000;
    } else if (int.tryParse(color.getAttribute('theme') ?? '') case final index?) {
      base = index < theme.length ? theme[index] : null;
    } else if (int.tryParse(color.getAttribute('indexed') ?? '') case final index?) {
      // 64/65 are the system foreground/background: no fill of their own.
      base = index < _indexedColors.length ? _indexedColors[index] : null;
    }
    if (base == null) return null;
    final tint = double.tryParse(color.getAttribute('tint') ?? '');
    return tint == null || tint == 0 ? base : _applyTint(base, tint);
  }

  /// Lightens (tint > 0) or darkens (tint < 0) in HLS space (§18.8.19).
  static int _applyTint(int argb, double tint) {
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
      if (max == r) {
        h = ((g - b) / d) % 6;
      } else if (max == g) {
        h = (b - r) / d + 2;
      } else {
        h = (r - g) / d + 4;
      }
      h /= 6;
    }
    l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint;
    double channel(double t) {
      final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      final pp = 2 * l - q;
      var tt = t;
      if (tt < 0) tt += 1;
      if (tt > 1) tt -= 1;
      if (tt < 1 / 6) return pp + (q - pp) * 6 * tt;
      if (tt < 1 / 2) return q;
      if (tt < 2 / 3) return pp + (q - pp) * (2 / 3 - tt) * 6;
      return pp;
    }

    final (nr, ng, nb) = s == 0 ? (l, l, l) : (channel(h + 1 / 3), channel(h), channel(h - 1 / 3));
    int byte(double v) => (v * 255).round().clamp(0, 255);
    return (argb & 0xFF000000) | (byte(nr) << 16) | (byte(ng) << 8) | byte(nb);
  }

  /// The legacy 64-colour palette (§18.8.27), for `indexed` colours.
  static const _indexedColors = [
    0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF, //
    0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF,
    0xFF800000, 0xFF008000, 0xFF000080, 0xFF808000, 0xFF800080, 0xFF008080, 0xFFC0C0C0, 0xFF808080,
    0xFF9999FF, 0xFF993366, 0xFFFFFFCC, 0xFFCCFFFF, 0xFF660066, 0xFFFF8080, 0xFF0066CC, 0xFFCCCCFF,
    0xFF000080, 0xFFFF00FF, 0xFFFFFF00, 0xFF00FFFF, 0xFF800080, 0xFF800000, 0xFF008080, 0xFF0000FF,
    0xFF00CCFF, 0xFFCCFFFF, 0xFFCCFFCC, 0xFFFFFF99, 0xFF99CCFF, 0xFFFF99CC, 0xFFCC99FF, 0xFFFFCC99,
    0xFF3366FF, 0xFF33CCCC, 0xFF99CC00, 0xFFFFCC00, 0xFFFF9900, 0xFFFF6600, 0xFF666699, 0xFF969696,
    0xFF003366, 0xFF339966, 0xFF003300, 0xFF333300, 0xFF993300, 0xFF993366, 0xFF333399, 0xFF333333,
  ];

  // --- Worksheets (§18.3) ----------------------------------------------------

  static Worksheet _worksheet(
    String source, {
    required String name,
    required SheetVisibility visibility,
    required List<String> sharedStrings,
    required List<CellStyle> styles,
    required List<DifferentialStyle> differential,
    required List<int> theme,
    required bool date1904,
    required Map<String, String> links,
    Map<CellAddress, CellComment> comments = const {},
  }) {
    final rows = <int, List<SheetCell?>>{};
    var frozenRows = 0;
    var frozenColumns = 0;
    var sawSheetView = false;

    var defaultColumnWidth = 8.43;
    var defaultRowHeight = 15.0;
    final columnWidths = <int, double>{};
    final rowHeights = <int, double>{};
    final hiddenColumns = <int>{};
    final hiddenRows = <int>{};
    final merges = <CellRange>[];
    final hyperlinks = <CellAddress, String>{};

    var rowIndex = -1;
    var columnIndex = -1;
    String? cellType;
    var styleIndex = 0;
    String? value;
    String? formula;
    // The cell's <f>: its t (shared, array) and a shared formula's si.
    String? formulaType;
    String? sharedIndex;
    // Shared formulas by si: the text, written for the cell that holds it.
    final sharedFormulas = <String, (String, int, int)>{};
    final text = StringBuffer();

    // Conditional formatting, collected as it streams by.
    final rules = <ConditionalRule>[];
    var ruleRanges = <CellRange>[];
    Map<String, String>? rule;
    final ruleFormulas = <String>[];
    final rulePoints = <ConditionalValuePoint>[];
    final ruleColors = <int>[];
    // Which element's text is being collected: v, f, or t (inline string).
    String? collecting;
    var inCell = false;
    var inInlineString = false;
    var phoneticDepth = 0;

    var slots = 0;

    void putCell() {
      final style = styleIndex < styles.length ? styles[styleIndex] : CellStyle.plain;
      var cellFormula = formula;
      if (formulaType == 'shared' && sharedIndex != null) {
        if (cellFormula != null && cellFormula.isNotEmpty) {
          sharedFormulas[sharedIndex] = (cellFormula, rowIndex, columnIndex);
        } else if (sharedFormulas[sharedIndex] case (final master, final row, final column)) {
          cellFormula = shiftFormula(master, rowIndex - row, columnIndex - column);
        }
      }
      // Outside the grid Excel allows (a damaged or hostile file).
      if (rowIndex < 0 || rowIndex >= _maxRows || columnIndex < 0 || columnIndex >= _maxColumns) return;
      final cellValue = _cellValue(
        cellType,
        value,
        cellFormula,
        sharedStrings,
        array: formulaType == 'array',
        date1904: date1904,
      );
      // Blank cells only matter when they're filled, bordered or noted.
      if (cellValue == null &&
          style.fillColor == null &&
          style.borders.isEmpty &&
          !comments.containsKey((row: rowIndex, column: columnIndex))) {
        return;
      }
      final row = rows.putIfAbsent(rowIndex, () => <SheetCell?>[]);
      // Rows are padded up to their last cell; a sheet of scattered far-off
      // cells would pad millions of empty slots, so stop at a budget.
      final padding = columnIndex + 1 - row.length;
      if (padding > 0) {
        if (slots + padding > _maxCellSlots) return;
        slots += padding;
      }
      while (row.length <= columnIndex) {
        row.add(null);
      }
      row[columnIndex] = SheetCell(cellValue, style: style, date1904: date1904);
    }

    for (final event in _events(source)) {
      switch (event) {
        case XmlStartElementEvent(:final localName, :final attributes, :final isSelfClosing):
          String? attr(String name) => attributes.where((a) => a.localName == name).firstOrNull?.value;
          switch (localName) {
            case 'sheetView':
              sawSheetView = true;
            case 'pane' when sawSheetView:
              final state = attr('state');
              if (state == 'frozen' || state == 'frozenSplit') {
                frozenColumns = double.tryParse(attr('xSplit') ?? '')?.toInt() ?? 0;
                frozenRows = double.tryParse(attr('ySplit') ?? '')?.toInt() ?? 0;
              }
            case 'sheetFormatPr':
              defaultRowHeight = double.tryParse(attr('defaultRowHeight') ?? '') ?? defaultRowHeight;
              if (double.tryParse(attr('defaultColWidth') ?? '') case final width?) {
                defaultColumnWidth = width;
              } else if (int.tryParse(attr('baseColWidth') ?? '') case final base?) {
                // §18.3.1.81 leaves out padding; Excel shows the default
                // base of 8 as 8.43 characters (64 px), so add the same.
                defaultColumnWidth = base + 0.43;
              }
            case 'col':
              final first = (int.tryParse(attr('min') ?? '') ?? 1) - 1;
              // Some writers span to column 16384 for one style; cap the loop.
              final last = ((int.tryParse(attr('max') ?? '') ?? first + 1) - 1).clamp(first, first + 1024);
              final width = double.tryParse(attr('width') ?? '');
              final hidden = attr('hidden') == '1' || attr('hidden') == 'true';
              for (var c = first; c <= last; c++) {
                if (width != null) columnWidths[c] = width;
                if (hidden) hiddenColumns.add(c);
              }
            case 'row':
              rowIndex = (int.tryParse(attr('r') ?? '') ?? (rowIndex + 2)) - 1;
              columnIndex = -1;
              if (double.tryParse(attr('ht') ?? '') case final height?) rowHeights[rowIndex] = height;
              if (attr('hidden') == '1' || attr('hidden') == 'true') hiddenRows.add(rowIndex);
            case 'mergeCell':
              if (_range(attr('ref')) case final range?) merges.add(range);
            case 'hyperlink':
              final target = switch (attr('id')) {
                final id? => links[id],
                null => null,
              };
              final location = attr('location');
              final link = target ?? (location == null ? null : '#$location');
              final range = _range(attr('ref'));
              if (link != null && range != null) hyperlinks[(row: range.firstRow, column: range.firstColumn)] = link;
            case 'c':
              final ref = attr('r');
              columnIndex = ref == null ? columnIndex + 1 : _columnOf(ref);
              if (ref != null && rowIndex < 0) rowIndex = _rowOf(ref);
              cellType = attr('t');
              styleIndex = int.tryParse(attr('s') ?? '') ?? 0;
              value = null;
              formula = null;
              formulaType = null;
              sharedIndex = null;
              inCell = true;
              if (isSelfClosing) {
                putCell();
                inCell = false;
              }
            case 'v' when inCell && !isSelfClosing:
              collecting = 'v';
              text.clear();
            case 'f' when inCell:
              formula ??= '';
              formulaType = attr('t');
              sharedIndex = attr('si');
              if (!isSelfClosing) {
                collecting = 'f';
                text.clear();
              }
            case 'is' when inCell:
              inInlineString = true;
              value ??= '';
            case 'rPh' when inInlineString && !isSelfClosing:
              phoneticDepth++;
            case 't' when inInlineString && phoneticDepth == 0 && !isSelfClosing:
              collecting = 't';
              text.clear();
            case 'conditionalFormatting':
              ruleRanges = [for (final ref in (attr('sqref') ?? '').split(' ')) ?_range(ref)];
            case 'cfRule':
              rule = {for (final a in attributes) a.localName: a.value};
              ruleFormulas.clear();
              rulePoints.clear();
              ruleColors.clear();
              if (isSelfClosing) {
                rules.add(_rule(rule, ruleRanges, ruleFormulas, rulePoints, ruleColors, differential));
                rule = null;
              }
            case 'formula' when rule != null && !isSelfClosing:
              collecting = 'formula';
              text.clear();
            case 'cfvo' when rule != null:
              rulePoints.add(ConditionalValuePoint(attr('type') ?? 'min', attr('val')));
            case 'color' when rule != null:
              if (_colorOf(attr, theme) case final color?) ruleColors.add(color);
          }
        case XmlEndElementEvent(:final localName):
          switch (localName) {
            case 'v' when collecting == 'v':
              value = text.toString();
              collecting = null;
            case 'f' when collecting == 'f':
              formula = text.toString();
              collecting = null;
            case 'formula' when collecting == 'formula':
              ruleFormulas.add(_unescapeOoxml(text.toString()));
              collecting = null;
            case 'cfRule' when rule != null:
              rules.add(_rule(rule, ruleRanges, ruleFormulas, rulePoints, ruleColors, differential));
              rule = null;
            case 't' when collecting == 't':
              value = '${value ?? ''}$text';
              collecting = null;
            case 'rPh':
              phoneticDepth--;
            case 'is':
              inInlineString = false;
            case 'c' when inCell:
              putCell();
              inCell = false;
            case 'sheetView':
              sawSheetView = false;
          }
        case XmlTextEvent(value: final chunk) when collecting != null:
          text.write(chunk);
        case XmlCDATAEvent(value: final chunk) when collecting != null:
          text.write(chunk);
        default:
          break;
      }
    }

    // A note on a cell outside the data still needs its row.
    for (final address in comments.keys) {
      rows.putIfAbsent(address.row, () => <SheetCell?>[]);
    }
    final lastRow = rows.keys.fold(-1, (a, b) => a > b ? a : b);
    // Rows without cells share one empty list.
    const noCells = <SheetCell?>[];
    return Worksheet(
      name: name,
      visibility: visibility,
      rows: ConditionalFormatting.apply(
        [for (var r = 0; r <= lastRow; r++) rows[r] ?? noCells],
        rules,
        date1904: date1904,
      ),
      comments: comments,
      frozenRows: frozenRows,
      frozenColumns: frozenColumns,
      layout: SheetLayout(
        defaultColumnWidth: defaultColumnWidth,
        defaultRowHeight: defaultRowHeight,
        columnWidths: columnWidths,
        rowHeights: rowHeights,
        hiddenColumns: hiddenColumns,
        hiddenRows: hiddenRows,
      ),
      merges: merges,
      hyperlinks: hyperlinks,
    );
  }

  /// `B2:C5` (or a single `B2`) -> a zero-based range.
  static CellRange? _range(String? ref) {
    if (ref == null || ref.isEmpty) return null;
    final parts = ref.split(':');
    final first = parts.first;
    final last = parts.length > 1 ? parts[1] : first;
    if (!RegExp(r'^\$?[A-Za-z]{1,3}\$?\d{1,7}$').hasMatch(first) || !RegExp(r'^\$?[A-Za-z]{1,3}\$?\d{1,7}$').hasMatch(last)) {
      return null;
    }
    final (firstRow, firstColumn) = (_rowOf(first), _columnOf(first.replaceAll(r'$', '')));
    final (lastRow, lastColumn) = (_rowOf(last), _columnOf(last.replaceAll(r'$', '')));
    // Row 0 (`A0`) and anything past Excel's grid don't exist.
    if (firstRow < 0 || firstColumn < 0 || firstRow >= _maxRows || firstColumn >= _maxColumns) return null;
    if (lastRow < firstRow || lastColumn < firstColumn) return null;
    return CellRange(
      firstRow: firstRow,
      firstColumn: firstColumn,
      lastRow: lastRow < _maxRows ? lastRow : _maxRows - 1,
      lastColumn: lastColumn < _maxColumns ? lastColumn : _maxColumns - 1,
    );
  }

  /// A `<cfRule>` from its attributes and children.
  static ConditionalRule _rule(
    Map<String, String> attributes,
    List<CellRange> ranges,
    List<String> formulas,
    List<ConditionalValuePoint> points,
    List<int> colors,
    List<DifferentialStyle> differential,
  ) {
    bool flag(String name, bool absent) => switch (attributes[name]) {
          null => absent,
          final v => v == '1' || v == 'true',
        };
    int number(String name, int absent) => int.tryParse(attributes[name] ?? '') ?? absent;
    final dxfId = int.tryParse(attributes['dxfId'] ?? '');
    return ConditionalRule(
      ranges: List.of(ranges),
      type: attributes['type'] ?? '',
      priority: number('priority', 0),
      stopIfTrue: flag('stopIfTrue', false),
      style: dxfId != null && dxfId >= 0 && dxfId < differential.length ? differential[dxfId] : null,
      operator: attributes['operator'],
      formulas: List.of(formulas),
      text: attributes['text'],
      rank: number('rank', 10),
      percent: flag('percent', false),
      bottom: flag('bottom', false),
      aboveAverage: flag('aboveAverage', true),
      equalAverage: flag('equalAverage', false),
      standardDeviations: number('stdDev', 0),
      points: List.of(points),
      colors: List.of(colors),
      minLength: number('minLength', 10),
      maxLength: number('maxLength', 90),
    );
  }

  /// A cell's value from its type (`t`), `<v>`/inline text and `<f>`.
  static CellValue? _cellValue(
    String? type,
    String? raw,
    String? formula,
    List<String> sharedStrings, {
    bool array = false,
    bool date1904 = false,
  }) {
    CellValue? result;
    switch (type) {
      case 's':
        final index = int.tryParse(raw ?? '');
        result = index != null && index >= 0 && index < sharedStrings.length ? TextValue(sharedStrings[index]) : null;
      case 'inlineStr':
        result = raw == null ? null : TextValue(_unescapeOoxml(raw));
      case 'str':
        result = raw == null ? null : TextValue(_unescapeOoxml(raw));
      case 'b':
        result = raw == null ? null : BoolValue(raw.trim() == '1' || raw.trim() == 'true');
      case 'e':
        result = raw == null ? null : ErrorValue(raw);
      case 'd':
        final date = DateTime.tryParse(raw ?? '');
        result = date == null ? null : NumberValue(_dateToSerial(date) - (date1904 ? 1462 : 0));
      default:
        // Plain decimals only: num.tryParse would also take NaN, Infinity
        // and hex, which no spreadsheet writes as a number.
        final text = raw?.trim() ?? '';
        final number = _decimal.hasMatch(text) ? num.tryParse(text) : null;
        result = number == null || !number.isFinite ? null : NumberValue(number is double && number == number.truncateToDouble() && number.abs() < 1e15 ? number.toInt() : number);
    }
    if (formula == null) return result;
    return FormulaValue(_unescapeOoxml(formula), cached: result, array: array);
  }

  static num _dateToSerial(DateTime date) {
    final utc = DateTime.utc(date.year, date.month, date.day, date.hour, date.minute, date.second, date.millisecond);
    final days = utc.difference(DateTime.utc(1899, 12, 30)).inMilliseconds / 86400000;
    return days < 61 ? days - 1 : days;
  }

  /// Excel's grid: 1,048,576 rows by 16,384 columns (XFD).
  static const _maxRows = 1048576;
  static const _maxColumns = 16384;

  /// Cell slots (cells plus the empty ones padding rows up to them) one
  /// sheet may take.
  static const _maxCellSlots = 10000000;

  static final _decimal = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

  /// `B12` -> 1 (zero-based column).
  static int _columnOf(String ref) {
    var column = 0;
    for (final unit in ref.codeUnits) {
      final upper = unit & ~0x20;
      if (upper < 0x41 || upper > 0x5A) break;
      column = column * 26 + (upper - 0x40);
    }
    return column - 1;
  }

  /// `B12` -> 11 (zero-based row).
  static int _rowOf(String ref) {
    final digits = ref.replaceAll(RegExp('[^0-9]'), '');
    return (int.tryParse(digits) ?? 1) - 1;
  }
}
