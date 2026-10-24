import 'dart:math' as math;

import 'workbook.dart';

/// A conditional format's look (`<dxf>`, §18.8.17): only what it sets.
class DifferentialStyle {
  const DifferentialStyle({this.bold, this.italic, this.underline, this.strikethrough, this.textColor, this.fillColor});

  final bool? bold;
  final bool? italic;
  final bool? underline;
  final bool? strikethrough;

  /// 0xAARRGGBB.
  final int? textColor;
  final int? fillColor;
}

/// A threshold of a colour scale or data bar (`<cfvo>`, §18.3.1.11):
/// `min`, `max`, `num`, `percent` or `percentile`, with its value.
class ConditionalValuePoint {
  const ConditionalValuePoint(this.type, [this.value]);

  final String type;
  final String? value;
}

/// One conditional-formatting rule (`<cfRule>`, §18.3.1.10) and the
/// ranges it covers. [ConditionalFormatting.apply] evaluates the types a
/// reader can without a formula engine: comparisons with constants or a
/// single cell, text matches, blanks, errors, top/bottom N, above/below
/// average, duplicates, colour scales and data bars. `expression` and
/// `timePeriod` rules need formulas evaluated and are left out.
class ConditionalRule {
  const ConditionalRule({
    required this.ranges,
    required this.type,
    this.priority = 0,
    this.stopIfTrue = false,
    this.style,
    this.operator,
    this.formulas = const [],
    this.text,
    this.rank = 10,
    this.percent = false,
    this.bottom = false,
    this.aboveAverage = true,
    this.equalAverage = false,
    this.standardDeviations = 0,
    this.points = const [],
    this.colors = const [],
    this.minLength = 10,
    this.maxLength = 90,
  });

  final List<CellRange> ranges;
  final String type;
  final int priority;
  final bool stopIfTrue;
  final DifferentialStyle? style;

  /// `cellIs`: `greaterThan`, `between`, ...
  final String? operator;
  final List<String> formulas;

  /// `containsText`, `beginsWith`, ...: the text looked for.
  final String? text;

  /// `top10`.
  final int rank;
  final bool percent;
  final bool bottom;

  /// `aboveAverage`.
  final bool aboveAverage;
  final bool equalAverage;
  final int standardDeviations;

  /// `colorScale` (2 or 3) and `dataBar` (2) thresholds, with the scale's
  /// colours (0xAARRGGBB) or the bar's one.
  final List<ConditionalValuePoint> points;
  final List<int> colors;

  /// A data bar's shortest and longest bar, in percent of the cell.
  final int minLength;
  final int maxLength;
}

abstract final class ConditionalFormatting {
  /// Cells beyond these aren't looked at: a rule over whole columns covers
  /// the sheet's cells, not a million empty rows.
  static const int _maxCells = 1000000;

  /// [rows] with [rules] applied: each matching cell's style gets the
  /// rule's look on top (the earliest-priority rule wins a property, and a
  /// `stopIfTrue` match stops later rules), colour scales fill cells and
  /// data bars are attached. Blank cells a rule colours are added.
  static List<List<SheetCell?>> apply(List<List<SheetCell?>> rows, List<ConditionalRule> rules, {bool date1904 = false}) {
    if (rules.isEmpty || rows.isEmpty) return rows;
    final columnCount = rows.fold(0, (widest, row) => math.max(widest, row.length));
    // By priority, then file order (List.sort isn't stable).
    final ordered = [for (var i = 0; i < rules.length; i++) (i, rules[i])]
      ..sort((a, b) => a.$2.priority != b.$2.priority ? a.$2.priority.compareTo(b.$2.priority) : a.$1.compareTo(b.$1));
    final overrides = <(int, int), _Override>{};

    for (final (_, rule) in ordered) {
      final cells = <(int, int)>[];
      for (final range in rule.ranges) {
        final lastRow = math.min(range.lastRow, rows.length - 1);
        final lastColumn = math.min(range.lastColumn, columnCount - 1);
        for (var r = range.firstRow; r <= lastRow; r++) {
          for (var c = range.firstColumn; c <= lastColumn; c++) {
            if (cells.length >= _maxCells) break;
            cells.add((r, c));
          }
        }
      }
      if (cells.isEmpty) continue;
      SheetCell? cellAt(int r, int c) => r >= 0 && r < rows.length && c >= 0 && c < rows[r].length ? rows[r][c] : null;
      final evaluate = _evaluator(rule, [for (final (r, c) in cells) cellAt(r, c)], cellAt);
      if (evaluate == null) continue;
      for (final (r, c) in cells) {
        final current = overrides[(r, c)];
        if (current?.stopped ?? false) continue;
        final effect = evaluate(cellAt(r, c), r, c);
        if (effect == null) continue;
        final override = current ?? (overrides[(r, c)] = _Override());
        override.add(effect);
        if (rule.stopIfTrue) override.stopped = true;
      }
    }
    if (overrides.isEmpty) return rows;

    final result = [for (final row in rows) [...row]];
    overrides.forEach((key, override) {
      if (override.isEmpty) return;
      final (r, c) = key;
      final row = result[r];
      while (row.length <= c) {
        row.add(null);
      }
      final cell = row[c];
      final style = (cell?.style ?? CellStyle.plain).overriddenBy(
        bold: override.bold,
        italic: override.italic,
        underline: override.underline,
        strikethrough: override.strikethrough,
        textColor: override.textColor,
        fillColor: override.fillColor,
      );
      row[c] = SheetCell(cell?.value, style: style, date1904: cell?.date1904 ?? date1904, dataBar: override.dataBar);
    });
    return result;
  }

  /// What [rule] does to a cell, or null when it doesn't apply; null as a
  /// whole for a rule type this can't evaluate.
  static _Effect? Function(SheetCell?, int, int)? _evaluator(
    ConditionalRule rule,
    List<SheetCell?> cells,
    SheetCell? Function(int, int) cellAt,
  ) {
    _Effect styled() => _Effect(style: rule.style);
    switch (rule.type) {
      case 'cellIs':
        final origin = rule.ranges.first;
        Object? operand(int index, int r, int c) {
          if (index >= rule.formulas.length) return null;
          return _constant(rule.formulas[index], r - origin.firstRow, c - origin.firstColumn, cellAt);
        }
        return (cell, r, c) {
          final value = _comparable(cell);
          if (value == null) return null;
          final a = operand(0, r, c);
          // An operand this can't work out (a formula, a blank cell)
          // matches nothing, not even notEqual.
          if (a == null) return null;
          final matches = switch (rule.operator) {
            'between' => _between(value, a, operand(1, r, c)),
            'notBetween' => !_between(value, a, operand(1, r, c)),
            'equal' => _compare(value, a) == 0,
            'notEqual' => _compare(value, a) != 0,
            'greaterThan' => (_compare(value, a) ?? 0) > 0,
            'lessThan' => (_compare(value, a) ?? 0) < 0,
            'greaterThanOrEqual' => (_compare(value, a) ?? -1) >= 0,
            'lessThanOrEqual' => (_compare(value, a) ?? 1) <= 0,
            _ => false,
          };
          return matches ? styled() : null;
        };
      case 'containsText' || 'notContainsText' || 'beginsWith' || 'endsWith':
        final needle = (rule.text ?? '').toLowerCase();
        return (cell, _, _) {
          final text = (cell?.text ?? '').toLowerCase();
          final matches = switch (rule.type) {
            'containsText' => text.contains(needle),
            'notContainsText' => !text.contains(needle),
            'beginsWith' => text.startsWith(needle),
            _ => text.endsWith(needle),
          };
          return matches ? styled() : null;
        };
      case 'containsBlanks' || 'notContainsBlanks':
        final wantBlank = rule.type == 'containsBlanks';
        return (cell, _, _) => (cell?.text ?? '').trim().isEmpty == wantBlank ? styled() : null;
      case 'containsErrors' || 'notContainsErrors':
        final wantError = rule.type == 'containsErrors';
        return (cell, _, _) => _isError(cell) == wantError ? styled() : null;
      case 'top10':
        final values = [for (final cell in cells) ?_number(cell)]..sort();
        if (values.isEmpty) return null;
        final count = rule.percent ? math.max(1, (values.length * rule.rank / 100).floor()) : rule.rank;
        if (count < 1) return null;
        final n = math.min(count, values.length);
        final threshold = rule.bottom ? values[n - 1] : values[values.length - n];
        return (cell, _, _) {
          final v = _number(cell);
          if (v == null) return null;
          return (rule.bottom ? v <= threshold : v >= threshold) ? styled() : null;
        };
      case 'aboveAverage':
        final values = [for (final cell in cells) ?_number(cell)];
        if (values.isEmpty) return null;
        final average = values.reduce((a, b) => a + b) / values.length;
        var threshold = average;
        if (rule.standardDeviations > 0 && values.length > 1) {
          final variance = values.fold(0.0, (sum, v) => sum + (v - average) * (v - average)) / (values.length - 1);
          final offset = rule.standardDeviations * math.sqrt(variance);
          threshold = rule.aboveAverage ? average + offset : average - offset;
        }
        return (cell, _, _) {
          final v = _number(cell);
          if (v == null) return null;
          final matches = rule.aboveAverage
              ? (rule.equalAverage ? v >= threshold : v > threshold)
              : (rule.equalAverage ? v <= threshold : v < threshold);
          return matches ? styled() : null;
        };
      case 'duplicateValues' || 'uniqueValues':
        final counts = <String, int>{};
        for (final cell in cells) {
          final key = (cell?.text ?? '').toLowerCase();
          if (key.trim().isEmpty) continue;
          counts[key] = (counts[key] ?? 0) + 1;
        }
        final wantDuplicate = rule.type == 'duplicateValues';
        return (cell, _, _) {
          final key = (cell?.text ?? '').toLowerCase();
          if (key.trim().isEmpty) return null;
          return ((counts[key] ?? 0) > 1) == wantDuplicate ? styled() : null;
        };
      case 'colorScale':
        if (rule.points.length < 2 || rule.colors.length != rule.points.length) return null;
        final values = [for (final cell in cells) ?_number(cell)]..sort();
        if (values.isEmpty) return null;
        final stops = [for (final point in rule.points) _threshold(point, values)];
        if (stops.contains(null)) return null;
        return (cell, _, _) {
          final v = _number(cell);
          if (v == null) return null;
          return _Effect(fillColor: _scaleColor(v, stops.cast<double>(), rule.colors));
        };
      case 'dataBar':
        if (rule.points.length < 2 || rule.colors.isEmpty) return null;
        final values = [for (final cell in cells) ?_number(cell)]..sort();
        if (values.isEmpty) return null;
        final low = _threshold(rule.points[0], values);
        final high = _threshold(rule.points[1], values);
        if (low == null || high == null) return null;
        return (cell, _, _) {
          final v = _number(cell);
          if (v == null) return null;
          final share = high > low ? ((v - low) / (high - low)).clamp(0.0, 1.0) : 1.0;
          final percent = rule.minLength + (rule.maxLength - rule.minLength) * share;
          return _Effect(dataBar: DataBar(percent / 100, rule.colors.first));
        };
      default:
        return null;
    }
  }

  /// A comparison operand: a number, quoted text, TRUE/FALSE, or one cell
  /// (its relative parts moved by [rows]/[columns] from the range's first
  /// cell). Null for anything needing a formula engine.
  static Object? _constant(String formula, int rows, int columns, SheetCell? Function(int, int) cellAt) {
    final text = formula.trim();
    if (num.tryParse(text) case final number?) return number;
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      return text.substring(1, text.length - 1).replaceAll('""', '"').toLowerCase();
    }
    switch (text.toUpperCase()) {
      case 'TRUE':
        return true;
      case 'FALSE':
        return false;
    }
    final ref = RegExp(r'^(\$?)([A-Za-z]{1,3})(\$?)(\d+)$').firstMatch(text);
    if (ref == null) return null;
    var column = 0;
    for (final unit in ref.group(2)!.toUpperCase().codeUnits) {
      column = column * 26 + (unit - 0x40);
    }
    var row = int.parse(ref.group(4)!);
    if (ref.group(1)!.isEmpty) column += columns;
    if (ref.group(3)!.isEmpty) row += rows;
    return _comparable(cellAt(row - 1, column - 1));
  }

  /// A cell's value for comparing: a number, lower-cased text or a bool;
  /// null for a blank or an error.
  static Object? _comparable(SheetCell? cell) {
    final value = switch (cell?.value) {
      FormulaValue(:final cached) => cached,
      final other => other,
    };
    return switch (value) {
      NumberValue(:final value) => value,
      TextValue(:final text) when text.isNotEmpty => text.toLowerCase(),
      BoolValue(:final value) => value,
      _ => null,
    };
  }

  /// Like Excel: numbers before text before booleans; null when [b] is
  /// unknown.
  static int? _compare(Object a, Object? b) {
    if (b == null) return null;
    int rank(Object v) => v is num ? 0 : (v is String ? 1 : 2);
    if (rank(a) != rank(b)) return rank(a).compareTo(rank(b));
    return switch (a) {
      final num n => n.compareTo(b as num),
      final String s => s.compareTo(b as String),
      final bool flag => (flag ? 1 : 0).compareTo((b as bool) ? 1 : 0),
      _ => null,
    };
  }

  static bool _between(Object value, Object? a, Object? b) {
    final low = _compare(value, a);
    final high = _compare(value, b);
    if (low == null || high == null) return false;
    // Either order: Excel accepts between 10 and 1.
    return (low >= 0 && high <= 0) || (low <= 0 && high >= 0);
  }

  static double? _number(SheetCell? cell) => cell?.number?.toDouble();

  static bool _isError(SheetCell? cell) => switch (cell?.value) {
        ErrorValue() || FormulaValue(cached: ErrorValue()) => true,
        _ => false,
      };

  /// A threshold's value among the range's sorted [values].
  static double? _threshold(ConditionalValuePoint point, List<double> values) {
    final given = double.tryParse(point.value ?? '');
    switch (point.type) {
      case 'min' || 'autoMin':
        return values.first;
      case 'max' || 'autoMax':
        return values.last;
      case 'num':
        return given;
      case 'percent':
        return given == null ? null : values.first + (values.last - values.first) * given / 100;
      case 'percentile':
        if (given == null) return null;
        // PERCENTILE.INC.
        final position = (values.length - 1) * given.clamp(0, 100) / 100;
        final lower = position.floor();
        final upper = math.min(lower + 1, values.length - 1);
        return values[lower] + (values[upper] - values[lower]) * (position - lower);
      default:
        return null;
    }
  }

  /// [value]'s colour on a scale with [stops] (ascending) and [colors].
  static int _scaleColor(double value, List<double> stops, List<int> colors) {
    if (value <= stops.first) return colors.first;
    if (value >= stops.last) return colors.last;
    for (var i = 0; i < stops.length - 1; i++) {
      if (value <= stops[i + 1]) {
        final span = stops[i + 1] - stops[i];
        final t = span <= 0 ? 1.0 : (value - stops[i]) / span;
        return _mix(colors[i], colors[i + 1], t);
      }
    }
    return colors.last;
  }

  static int _mix(int a, int b, double t) {
    int channel(int shift) {
      final x = (a >> shift) & 0xFF;
      final y = (b >> shift) & 0xFF;
      return (x + (y - x) * t).round().clamp(0, 255);
    }

    return 0xFF000000 | (channel(16) << 16) | (channel(8) << 8) | channel(0);
  }
}

class _Effect {
  const _Effect({this.style, this.fillColor, this.dataBar});

  final DifferentialStyle? style;
  final int? fillColor;
  final DataBar? dataBar;
}

/// What the matching rules do to one cell: the first rule (by priority)
/// to set a property keeps it.
class _Override {
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strikethrough;
  int? textColor;
  int? fillColor;
  DataBar? dataBar;
  bool stopped = false;

  bool get isEmpty =>
      bold == null &&
      italic == null &&
      underline == null &&
      strikethrough == null &&
      textColor == null &&
      fillColor == null &&
      dataBar == null;

  void add(_Effect effect) {
    final style = effect.style;
    bold ??= style?.bold;
    italic ??= style?.italic;
    underline ??= style?.underline;
    strikethrough ??= style?.strikethrough;
    textColor ??= style?.textColor;
    fillColor ??= style?.fillColor ?? effect.fillColor;
    dataBar ??= effect.dataBar;
  }
}
