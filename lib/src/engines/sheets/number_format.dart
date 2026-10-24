import 'dart:math' as math;

/// An Excel number format code (ECMA-376 Part 1, §18.8.31), e.g. `#,##0.00`,
/// `0%`, `m/d/yyyy` or `$#,##0_);[Red]($#,##0)`, and how a number looks
/// under it.
///
/// Covers what spreadsheets use day to day: General, digit placeholders
/// (`0 # ?`), thousands separators and scaling commas, percent, scientific,
/// fractions, literal text, up to four `;` sections (positive; negative;
/// zero; text) with conditions, colours (ignored), currency tags, and dates,
/// times and elapsed time. Locale-specific built-in formats use their
/// en-US look.
class NumberFormat {
  const NumberFormat(this.code);

  final String code;

  static const general = NumberFormat('General');

  /// The format for a built-in `numFmtId` (§18.8.30), or null when the id
  /// isn't built in (the file then defines it in `<numFmts>`).
  static NumberFormat? builtIn(int id) {
    final code = _builtInCodes[id];
    return code == null ? null : NumberFormat(code);
  }

  bool get isGeneral => code.isEmpty || code.toLowerCase() == 'general';

  /// Whether this formats numbers as dates or times.
  bool get isDate => _parse(code).sections.any((s) => s.isDate);

  /// [value] under this format. A date format places [value] as days since
  /// 1900-01-00, or since 1904-01-01 with [date1904].
  String format(num value, {bool date1904 = false}) {
    if (isGeneral) return formatGeneral(value);
    if (value is double && (value.isNaN || value.isInfinite)) return formatGeneral(value);
    final parsed = _parse(code);
    final (section, negativeSign) = parsed.sectionFor(value);
    if (section == null) return formatGeneral(value);
    // Sections get the magnitude; a negative section shows its own sign
    // (e.g. `(#,##0)`), otherwise [negativeSign] asks for a `-`.
    final shown = value.abs();
    // Excel can't show a date before its epoch or after 9999-12-31.
    if (section.isDate && (value < 0 || value >= _maxDateSerial)) return '#####';
    final text = section.isDate ? _formatDate(section, shown, date1904) : _formatNumber(section, shown);
    return ((negativeSign && text.contains(RegExp('[1-9]'))) ? '-$text' : text).trim();
  }

  /// Excel's General format: integers as-is, other numbers to 10
  /// significant digits, and very large/small ones in scientific notation.
  static String formatGeneral(num value) {
    if (value is double && value.isNaN) return '#NUM!';
    if (value is double && value.isInfinite) return '#NUM!';
    if (value == 0) return '0';
    final magnitude = value.abs();
    if (value is int || (value == value.truncateToDouble() && magnitude < 1e11)) {
      if (magnitude < 1e11) return value is int ? '$value' : value.toStringAsFixed(0);
    }
    if (magnitude >= 1e11 || magnitude < 1e-9) return _scientific(value, 5);
    final fixed = value.toStringAsPrecision(10);
    if (fixed.contains('e')) return _scientific(value, 5);
    return _trimZeros(fixed);
  }

  static String _scientific(num value, int decimals) {
    final parts = value.toStringAsExponential(decimals).split('e');
    final mantissa = _trimZeros(parts[0]);
    final exponent = int.parse(parts[1]);
    final digits = exponent.abs().toString().padLeft(2, '0');
    return '${mantissa}E${exponent < 0 ? '-' : '+'}$digits';
  }

  static String _trimZeros(String number) {
    if (!number.contains('.')) return number;
    var end = number.length;
    while (number[end - 1] == '0') {
      end--;
    }
    if (number[end - 1] == '.') end--;
    return number.substring(0, end);
  }

  @override
  bool operator ==(Object other) => other is NumberFormat && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'NumberFormat($code)';
}

// --- Built-in formats (§18.8.30; locale-dependent ones in en-US form) -------

const _shortDate = 'm/d/yyyy';

const _builtInCodes = <int, String>{
  0: 'General',
  1: '0',
  2: '0.00',
  3: '#,##0',
  4: '#,##0.00',
  5: r'$#,##0_);($#,##0)',
  6: r'$#,##0_);[Red]($#,##0)',
  7: r'$#,##0.00_);($#,##0.00)',
  8: r'$#,##0.00_);[Red]($#,##0.00)',
  9: '0%',
  10: '0.00%',
  11: '0.00E+00',
  12: '# ?/?',
  13: '# ??/??',
  14: _shortDate,
  15: 'd-mmm-yy',
  16: 'd-mmm',
  17: 'mmm-yy',
  18: 'h:mm AM/PM',
  19: 'h:mm:ss AM/PM',
  20: 'h:mm',
  21: 'h:mm:ss',
  22: 'm/d/yyyy h:mm',
  27: _shortDate,
  28: _shortDate,
  29: _shortDate,
  30: _shortDate,
  31: _shortDate,
  32: 'h:mm:ss',
  33: 'h:mm:ss',
  34: 'h:mm:ss',
  35: 'h:mm:ss',
  36: _shortDate,
  37: '#,##0_);(#,##0)',
  38: '#,##0_);[Red](#,##0)',
  39: '#,##0.00_);(#,##0.00)',
  40: '#,##0.00_);[Red](#,##0.00)',
  41: '_(* #,##0_);_(* (#,##0);_(* "-"_);_(@_)',
  42: r'_("$"* #,##0_);_("$"* (#,##0);_("$"* "-"_);_(@_)',
  43: '_(* #,##0.00_);_(* (#,##0.00);_(* "-"??_);_(@_)',
  44: r'_("$"* #,##0.00_);_("$"* (#,##0.00);_("$"* "-"??_);_(@_)',
  45: 'mm:ss',
  46: '[h]:mm:ss',
  47: 'mm:ss.0',
  48: '##0.0E+0',
  49: '@',
  50: _shortDate,
  51: _shortDate,
  52: _shortDate,
  53: _shortDate,
  54: _shortDate,
  55: _shortDate,
  56: _shortDate,
  57: _shortDate,
  58: _shortDate,
};

// --- Parsing ---------------------------------------------------------------

/// Parsed codes, per isolate: a sheet reuses a handful of formats for
/// thousands of cells.
final _cache = <String, _ParsedFormat>{};

_ParsedFormat _parse(String code) => _cache[code] ??= _ParsedFormat.parse(code);

class _ParsedFormat {
  _ParsedFormat(this.sections);

  final List<_Section> sections;

  factory _ParsedFormat.parse(String code) =>
      _ParsedFormat([for (final part in _splitSections(code)) _Section.parse(part)]);

  /// The section that formats [value], and whether a `-` must be added
  /// because the section chosen doesn't show the sign itself.
  (_Section?, bool) sectionFor(num value) {
    final numeric = sections.where((s) => !s.isTextOnly).toList();
    if (numeric.isEmpty) return (null, false);
    // Conditional sections ([>100] etc.) are tried in order.
    if (numeric.any((s) => s.condition != null)) {
      for (final section in numeric) {
        final condition = section.condition;
        if (condition == null || condition(value)) {
          return (section, value < 0 && condition == null && section != numeric.first);
        }
      }
      return (numeric.last, value < 0);
    }
    if (value > 0 || numeric.length == 1) return (numeric.first, value < 0);
    if (value < 0) return (numeric[1], false);
    return (numeric.length > 2 ? numeric[2] : numeric.first, false);
  }
}

List<String> _splitSections(String code) {
  final sections = <String>[];
  final current = StringBuffer();
  var inQuote = false;
  var inBracket = false;
  for (var i = 0; i < code.length; i++) {
    final char = code[i];
    if (char == '\\' && !inQuote && i + 1 < code.length) {
      current
        ..write(char)
        ..write(code[++i]);
      continue;
    }
    if (char == '"' && !inBracket) inQuote = !inQuote;
    if (char == '[' && !inQuote) inBracket = true;
    if (char == ']' && !inQuote) inBracket = false;
    if (char == ';' && !inQuote && !inBracket) {
      sections.add(current.toString());
      current.clear();
    } else {
      current.write(char);
    }
  }
  sections.add(current.toString());
  return sections;
}

sealed class _Token {
  const _Token();
}

class _Literal extends _Token {
  const _Literal(this.text);
  final String text;
}

/// A digit placeholder: `0` (always a digit), `#` (digit if significant)
/// or `?` (digit, else a space).
class _Digit extends _Token {
  const _Digit(this.kind);
  final String kind;
}

class _DecimalPoint extends _Token {
  const _DecimalPoint();
}

class _Comma extends _Token {
  const _Comma();
}

class _Percent extends _Token {
  const _Percent();
}

class _Exponent extends _Token {
  const _Exponent(this.showPlus);
  final bool showPlus;
}

class _Slash extends _Token {
  const _Slash();
}

class _TextPlaceholder extends _Token {
  const _TextPlaceholder();
}

class _GeneralToken extends _Token {
  const _GeneralToken();
}

/// A date/time part: `y`, `m`, `d`, `h`, `s` repeated [count] times.
class _DatePart extends _Token {
  const _DatePart(this.letter, this.count);
  final String letter;
  final int count;
}

/// `[h]`, `[mm]`, `[ss]`: total hours/minutes/seconds.
class _Elapsed extends _Token {
  const _Elapsed(this.letter, this.count);
  final String letter;
  final int count;
}

/// `AM/PM` or `A/P`, as written ([upper] case, [short] form).
class _AmPm extends _Token {
  const _AmPm({required this.short, required this.upper});
  final bool short;
  final bool upper;
}

class _Section {
  _Section(this.tokens, this.condition);

  final List<_Token> tokens;
  final bool Function(num)? condition;

  bool get isDate => tokens.any((t) => t is _DatePart || t is _Elapsed);

  /// A section with only `@` and literals formats text, not numbers.
  bool get isTextOnly =>
      tokens.any((t) => t is _TextPlaceholder) && !tokens.any((t) => t is _Digit || t is _GeneralToken || t is _DatePart);

  bool get hasAmPm => tokens.any((t) => t is _AmPm);

  factory _Section.parse(String code) {
    final tokens = <_Token>[];
    bool Function(num)? condition;
    var i = 0;
    while (i < code.length) {
      final char = code[i];
      final lower = char.toLowerCase();
      if (char == '"') {
        final end = code.indexOf('"', i + 1);
        final stop = end == -1 ? code.length : end;
        tokens.add(_Literal(code.substring(i + 1, stop)));
        i = stop + 1;
      } else if (char == '\\') {
        if (i + 1 < code.length) tokens.add(_Literal(code[i + 1]));
        i += 2;
      } else if (char == '_') {
        // Space as wide as the next character.
        tokens.add(const _Literal(' '));
        i += 2;
      } else if (char == '*') {
        // Repeat the next character to fill the cell: one space keeps the
        // gap it makes (e.g. between `$` and the amount).
        tokens.add(const _Literal(' '));
        i += 2;
      } else if (char == '[') {
        final end = code.indexOf(']', i);
        final stop = end == -1 ? code.length : end;
        final inner = code.substring(i + 1, stop);
        final elapsed = RegExp(r'^(h+|m+|s+)$', caseSensitive: false).firstMatch(inner);
        if (elapsed != null) {
          tokens.add(_Elapsed(inner[0].toLowerCase(), inner.length));
        } else if (inner.startsWith(r'$')) {
          // [$€-407]: currency symbol (before '-'), then a locale id.
          final dash = inner.indexOf('-');
          final symbol = inner.substring(1, dash == -1 ? inner.length : dash);
          if (symbol.isNotEmpty) tokens.add(_Literal(symbol));
        } else if (_conditionPattern.firstMatch(inner) case final match?) {
          condition = _condition(match.group(1)!, num.parse(match.group(2)!));
        }
        // Colours ([Red], [Color 10]) and anything else: not shown.
        i = stop + 1;
      } else if (lower == 'g' && code.substring(i).toLowerCase().startsWith('general')) {
        tokens.add(const _GeneralToken());
        i += 7;
      } else if (lower == 'a' && code.substring(i).toLowerCase().startsWith('am/pm')) {
        tokens.add(_AmPm(short: false, upper: char == 'A'));
        i += 5;
      } else if (lower == 'a' && code.substring(i).toLowerCase().startsWith('a/p')) {
        tokens.add(_AmPm(short: true, upper: char == 'A'));
        i += 3;
      } else if ('ymdhs'.contains(lower)) {
        var end = i;
        while (end < code.length && code[end].toLowerCase() == lower) {
          end++;
        }
        tokens.add(_DatePart(lower, end - i));
        i = end;
      } else if (lower == 'e' && i + 1 < code.length && (code[i + 1] == '+' || code[i + 1] == '-')) {
        tokens.add(_Exponent(code[i + 1] == '+'));
        i += 2;
      } else if (char == '0' || char == '#' || char == '?') {
        tokens.add(_Digit(char));
        i++;
      } else if (char == '.') {
        tokens.add(const _DecimalPoint());
        i++;
      } else if (char == ',') {
        tokens.add(const _Comma());
        i++;
      } else if (char == '%') {
        tokens.add(const _Percent());
        i++;
      } else if (char == '/') {
        tokens.add(const _Slash());
        i++;
      } else if (char == '@') {
        tokens.add(const _TextPlaceholder());
        i++;
      } else {
        tokens.add(_Literal(char));
        i++;
      }
    }
    return _Section(tokens, condition);
  }
}

final _conditionPattern = RegExp(r'^(<=|>=|<>|<|>|=)\s*(-?\d+(?:\.\d+)?)$');

bool Function(num) _condition(String op, num limit) => switch (op) {
      '<' => (v) => v < limit,
      '<=' => (v) => v <= limit,
      '>' => (v) => v > limit,
      '>=' => (v) => v >= limit,
      '<>' => (v) => v != limit,
      _ => (v) => v == limit,
    };

// --- Numbers ---------------------------------------------------------------

String _formatNumber(_Section section, num value) {
  final tokens = section.tokens;
  if (tokens.any((t) => t is _GeneralToken)) {
    return [
      for (final t in tokens)
        if (t is _GeneralToken) NumberFormat.formatGeneral(value) else if (t is _Literal) t.text,
    ].join();
  }
  final firstDigit = tokens.indexWhere((t) => t is _Digit);
  if (firstDigit == -1) {
    // No digits: only literals (e.g. `"-"` for zero), or `@`, or nothing -
    // an empty section (`;;;`, `0;;`) hides the value.
    if (tokens.isEmpty) return '';
    return [
      for (final t in tokens)
        if (t is _TextPlaceholder) NumberFormat.formatGeneral(value) else _literalText(t),
    ].join();
  }
  final percents = tokens.whereType<_Percent>().length;
  var scaled = value * math.pow(100, percents);

  if (tokens.any((t) => t is _Slash)) return _formatFraction(tokens, scaled);

  final exponentAt = tokens.indexWhere((t) => t is _Exponent);
  final mantissaEnd = exponentAt == -1 ? tokens.length : exponentAt;
  final lastDigit = tokens.sublist(0, mantissaEnd).lastIndexWhere((t) => t is _Digit);
  final pointAt = tokens.sublist(0, mantissaEnd).indexWhere((t) => t is _DecimalPoint);
  final integerEnd = pointAt == -1 ? lastDigit + 1 : pointAt;

  // Commas between integer digits turn on thousands separators; a run of
  // commas right after the integer digits scales by 1000 per comma.
  final lastIntegerDigit = tokens.sublist(0, integerEnd).lastIndexWhere((t) => t is _Digit);
  final grouping = [for (var i = firstDigit; i < lastIntegerDigit; i++) tokens[i]].any((t) => t is _Comma);
  var scaling = 0;
  for (var i = lastIntegerDigit + 1; i < mantissaEnd && tokens[i] is _Comma; i++) {
    scaling++;
  }
  if (pointAt != -1) {
    for (var i = lastDigit + 1; i < mantissaEnd && tokens[i] is _Comma; i++) {
      scaling++;
    }
  }
  scaled = scaled / math.pow(1000, scaling);

  final integerSlots = [
    for (var i = firstDigit; i < integerEnd; i++)
      if (tokens[i] is _Digit || tokens[i] is _Literal) tokens[i],
  ];
  final fractionSlots = pointAt == -1
      ? <_Token>[]
      : [
          for (var i = pointAt + 1; i <= lastDigit; i++)
            if (tokens[i] is _Digit || tokens[i] is _Literal) tokens[i],
        ];
  // toStringAsFixed takes at most 20; the slots past that show zeros.
  final decimals = math.min(fractionSlots.whereType<_Digit>().length, 20);

  var exponentText = '';
  if (exponentAt != -1) {
    final integerDigits = integerSlots.whereType<_Digit>().length;
    var exponent = 0;
    if (scaled != 0) {
      exponent = (math.log(scaled.abs()) / math.ln10).floor();
      // `##0.0E+0`: the exponent moves in steps of the integer digit count.
      if (integerDigits > 1 && integerSlots.any((t) => t is _Digit && t.kind == '#')) {
        exponent = (exponent / integerDigits).floor() * integerDigits;
      } else {
        exponent -= integerDigits - 1;
      }
      scaled = scaled / math.pow(10, exponent);
      // Rounding can carry into another digit (9.99 -> 10.0).
      if (double.parse(scaled.abs().toStringAsFixed(decimals)) >= math.pow(10, integerDigits)) {
        scaled /= 10;
        exponent += 1;
      }
    }
    final exponentToken = tokens[exponentAt] as _Exponent;
    final exponentDigits = tokens.sublist(exponentAt + 1).whereType<_Digit>().length;
    final sign = exponent < 0 ? '-' : (exponentToken.showPlus ? '+' : '');
    exponentText = 'E$sign${exponent.abs().toString().padLeft(math.max(exponentDigits, 1), '0')}';
  }

  final fixed = scaled.abs().toStringAsFixed(decimals);
  final point = fixed.indexOf('.');
  final integerPart = point == -1 ? fixed : fixed.substring(0, point);
  final fractionPart = point == -1 ? '' : fixed.substring(point + 1);

  final integerText = _fillInteger(integerSlots, integerPart == '0' ? '' : integerPart, grouping);
  final fractionText = _fillFraction(fractionSlots, fractionPart);

  final out = StringBuffer();
  for (var i = 0; i < firstDigit; i++) {
    out.write(_literalText(tokens[i]));
  }
  out.write(integerText);
  if (pointAt != -1) out.write('.$fractionText');
  out.write(exponentText);
  final suffixStart = exponentAt == -1 ? lastDigit + 1 : tokens.lastIndexWhere((t) => t is _Digit) + 1;
  for (var i = suffixStart; i < tokens.length; i++) {
    out.write(_literalText(tokens[i]));
  }
  return out.toString();
}

String _literalText(_Token token) => switch (token) {
      _Literal(:final text) => text,
      _Percent() => '%',
      _TextPlaceholder() => '',
      _ => '',
    };

/// Places [digits] into the integer placeholders right to left; extra
/// digits go before the leftmost one.
String _fillInteger(List<_Token> slots, String digits, bool grouping) {
  final placeholders = slots.whereType<_Digit>().toList();
  final hasInnerLiterals = slots.any((t) => t is _Literal);
  if (grouping || !hasInnerLiterals) {
    // Pad to the placeholders' minimum, then group.
    var text = digits;
    final buffer = StringBuffer();
    for (var i = placeholders.length - 1, d = text.length - 1; i >= 0; i--, d--) {
      if (d >= 0) continue;
      final kind = placeholders[i].kind;
      if (kind == '0') {
        buffer.write('0');
      } else if (kind == '?') {
        buffer.write(' ');
      }
    }
    text = buffer.toString().split('').reversed.join() + text;
    if (grouping) text = _group(text);
    return text;
  }
  // Placeholders with literals between them, e.g. `000-00-0000`.
  final out = <String>[];
  var d = digits.length - 1;
  for (var i = slots.length - 1; i >= 0; i--) {
    final slot = slots[i];
    if (slot is _Literal) {
      out.add(slot.text);
      continue;
    }
    final kind = (slot as _Digit).kind;
    final isLeftmost = identical(slot, placeholders.first);
    if (d >= 0) {
      if (isLeftmost) {
        out.add(digits.substring(0, d + 1));
        d = -1;
      } else {
        out.add(digits[d--]);
      }
    } else if (kind == '0') {
      out.add('0');
    } else if (kind == '?') {
      out.add(' ');
    }
  }
  return out.reversed.join();
}

String _group(String digits) {
  final leading = digits.length - digits.trimLeft().length;
  final core = digits.substring(leading);
  final out = StringBuffer(digits.substring(0, leading));
  for (var i = 0; i < core.length; i++) {
    if (i > 0 && (core.length - i) % 3 == 0) out.write(',');
    out.write(core[i]);
  }
  return out.toString();
}

/// Fraction digits left to right; trailing zeros vanish under `#` and turn
/// into spaces under `?`.
String _fillFraction(List<_Token> slots, String digits) {
  final out = <String>[];
  var d = 0;
  for (final slot in slots) {
    if (slot is _Literal) {
      out.add(slot.text);
    } else {
      out.add(d < digits.length ? digits[d] : '0');
      d++;
    }
  }
  // Walk back over trailing optional zeros.
  for (var i = slots.length - 1; i >= 0; i--) {
    final slot = slots[i];
    if (slot is! _Digit) continue;
    if (out[i] != '0' || slot.kind == '0') break;
    out[i] = slot.kind == '?' ? ' ' : '';
  }
  return out.join();
}

/// `# ?/?`, `# ??/??`, `?/8`, `0 ?/100`...
String _formatFraction(List<_Token> tokens, num value) {
  final slash = tokens.indexWhere((t) => t is _Slash);
  // Denominator: placeholders, or a fixed number written as digits.
  final denominatorTokens = tokens.sublist(slash + 1);
  var fixedDenominator = '';
  var denominatorDigits = 0;
  var denominatorEnd = slash + 1;
  for (var i = 0; i < denominatorTokens.length; i++) {
    final t = denominatorTokens[i];
    if (t is _Digit && t.kind != '0' && fixedDenominator.isEmpty) {
      denominatorDigits++;
    } else if ((t is _Digit && t.kind == '0') || (t is _Literal && RegExp(r'^\d+$').hasMatch(t.text))) {
      fixedDenominator += t is _Digit ? '0' : (t as _Literal).text;
    } else {
      break;
    }
    denominatorEnd = slash + 2 + i;
  }
  // Numerator: the placeholders just before the slash; a whole-number part
  // is a placeholder group before that, separated by a literal.
  var numeratorStart = slash;
  while (numeratorStart > 0 && tokens[numeratorStart - 1] is _Digit) {
    numeratorStart--;
  }
  final wholeTokens = tokens.sublist(0, numeratorStart);
  final hasWhole = wholeTokens.any((t) => t is _Digit);

  final magnitude = value.abs();
  final whole = hasWhole ? magnitude.floor() : 0;
  final remainder = magnitude - whole;
  int numerator;
  int denominator;
  final fixed = int.tryParse(fixedDenominator);
  if (fixed != null && fixed > 0) {
    denominator = fixed;
    numerator = (remainder * fixed).round();
  } else {
    // Past 9 digits a denominator overflows nothing useful: Excel itself
    // shows at most `?????????/?????????`.
    final maxDenominator = math.pow(10, denominatorDigits.clamp(1, 9)).toInt() - 1;
    (numerator, denominator) = _closestFraction(remainder, maxDenominator);
  }
  var wholeShown = whole;
  if (numerator == denominator) {
    wholeShown += 1;
    numerator = 0;
  }

  final out = StringBuffer(value < 0 ? '-' : '');
  if (hasWhole) {
    final firstDigit = wholeTokens.indexWhere((t) => t is _Digit);
    for (var i = 0; i < firstDigit; i++) {
      out.write(_literalText(wholeTokens[i]));
    }
    final wholeText = wholeShown == 0 && numerator != 0 ? '' : '$wholeShown';
    out.write(wholeText);
    for (var i = wholeTokens.lastIndexWhere((t) => t is _Digit) + 1; i < wholeTokens.length; i++) {
      out.write(_literalText(wholeTokens[i]));
    }
    if (numerator == 0) return (out.toString()).trimRight().isEmpty ? '0' : out.toString().trimRight();
  }
  out.write('$numerator/$denominator');
  for (var i = denominatorEnd; i < tokens.length; i++) {
    out.write(_literalText(tokens[i]));
  }
  return out.toString();
}

/// The fraction closest to [value] (0 <= value < 1, or any value for a
/// format without a whole part) with a denominator up to [maxDenominator]:
/// the best of the continued fraction's last convergent and semiconvergent,
/// found in a few dozen steps whatever the denominator limit.
(int, int) _closestFraction(num value, int maxDenominator) {
  final x = value.toDouble();
  // Convergents p/q, as (p0/q0, p1/q1) pairs.
  var (p0, q0, p1, q1) = (0, 1, 1, 0);
  var rest = x;
  for (var i = 0; i < 64; i++) {
    final a = rest.floor();
    final q2 = a * q1 + q0;
    if (q2 > maxDenominator) {
      // The best semiconvergent before the limit, if it beats p1/q1.
      final k = (maxDenominator - q0) ~/ q1;
      final (ps, qs) = (k * p1 + p0, k * q1 + q0);
      if (q1 == 0) return (ps, qs);
      return (x - ps / qs).abs() < (x - p1 / q1).abs() ? (ps, qs) : (p1, q1);
    }
    (p0, q0, p1, q1) = (p1, q1, a * p1 + p0, q2);
    final fraction = rest - a;
    if (fraction.abs() < 1e-12) break;
    rest = 1 / fraction;
  }
  return q1 == 0 ? (x.round(), 1) : (p1, q1);
}

// --- Dates and times ---------------------------------------------------------

/// The day after 9999-12-31, Excel's last date.
const _maxDateSerial = 2958466;

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// A calendar date and time. Not a [DateTime], which can't hold Excel's
/// 1900-02-29.
typedef _DateParts = ({int year, int month, int day, int weekday, int hour, int minute, int second, int millisecond});

/// Days since the epoch -> calendar date and time. 1900-based serials keep
/// Excel's (Lotus-compatible) fictitious 1900-02-29 at serial 60.
_DateParts _serialToDate(num serial, bool date1904, {required int fractionDigits}) {
  var days = serial.floor();
  final fraction = serial - days;
  // Round to what's shown: whole seconds, or the shown fraction of one.
  final unit = fractionDigits == 0 ? 1000 : math.pow(10, 3 - math.min(fractionDigits, 3)).toInt();
  var millis = ((fraction * 86400000) / unit).round() * unit;
  if (millis >= 86400000) {
    days += 1;
    millis -= 86400000;
  }
  final time = Duration(milliseconds: millis);
  final hour = time.inHours;
  final minute = time.inMinutes % 60;
  final second = time.inSeconds % 60;
  final millisecond = time.inMilliseconds % 1000;
  if (!date1904 && days == 60) {
    // The day that never was (a Wednesday), shown as Excel does.
    return (year: 1900, month: 2, day: 29, weekday: 3, hour: hour, minute: minute, second: second, millisecond: millisecond);
  }
  final base = date1904 ? DateTime.utc(1904) : (days < 60 ? DateTime.utc(1899, 12, 31) : DateTime.utc(1899, 12, 30));
  final date = base.add(Duration(days: days));
  return (
    year: date.year,
    month: date.month,
    day: date.day,
    weekday: date.weekday,
    hour: hour,
    minute: minute,
    second: second,
    millisecond: millisecond,
  );
}

String _formatDate(_Section section, num value, bool date1904) {
  final tokens = section.tokens;
  // Fractional seconds: `ss.0`, `ss.00`.
  var fractionDigits = 0;
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i] is _DecimalPoint) {
      var j = i + 1;
      while (j < tokens.length && tokens[j] is _Digit) {
        j++;
      }
      fractionDigits = math.max(fractionDigits, j - i - 1);
    }
  }
  final date = _serialToDate(value, date1904, fractionDigits: fractionDigits);
  final twelveHour = section.hasAmPm;
  final out = StringBuffer();

  // Which `m` tokens mean minutes: right after an hour, or right before a
  // second (literals between don't count).
  final dateParts = [for (var i = 0; i < tokens.length; i++) if (tokens[i] is _DatePart || tokens[i] is _Elapsed) i];
  bool isMinute(int index) {
    final at = dateParts.indexOf(index);
    final before = at > 0 ? tokens[dateParts[at - 1]] : null;
    final after = at + 1 < dateParts.length ? tokens[dateParts[at + 1]] : null;
    bool letterIs(_Token? t, String letter) =>
        (t is _DatePart && t.letter == letter) || (t is _Elapsed && t.letter == letter);
    return letterIs(before, 'h') || letterIs(after, 's');
  }

  String two(int n) => n.toString().padLeft(2, '0');
  final totalSeconds = (value * 86400).round();

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    switch (token) {
      case _DatePart(letter: 'y', :final count):
        out.write(count <= 2 ? two(date.year % 100) : date.year.toString().padLeft(4, '0'));
      case _DatePart(letter: 'm', :final count) when count <= 2 && isMinute(i):
        out.write(count == 1 ? '${date.minute}' : two(date.minute));
      case _DatePart(letter: 'm', :final count):
        out.write(switch (count) {
          1 => '${date.month}',
          2 => two(date.month),
          3 => _monthNames[date.month - 1].substring(0, 3),
          4 => _monthNames[date.month - 1],
          _ => _monthNames[date.month - 1][0],
        });
      case _DatePart(letter: 'd', :final count):
        out.write(switch (count) {
          1 => '${date.day}',
          2 => two(date.day),
          3 => _dayNames[date.weekday - 1].substring(0, 3),
          _ => _dayNames[date.weekday - 1],
        });
      case _DatePart(letter: 'h', :final count):
        var hour = date.hour;
        if (twelveHour) hour = hour % 12 == 0 ? 12 : hour % 12;
        out.write(count == 1 ? '$hour' : two(hour));
      case _DatePart(letter: 's', :final count):
        out.write(count == 1 ? '${date.second}' : two(date.second));
      case _Elapsed(:final letter, :final count):
        final total = switch (letter) {
          'h' => totalSeconds ~/ 3600,
          'm' => totalSeconds ~/ 60,
          _ => totalSeconds,
        };
        out.write(total.toString().padLeft(count, '0'));
      case _AmPm(:final short, :final upper):
        final pm = date.hour >= 12;
        final text = short ? (pm ? 'P' : 'A') : (pm ? 'PM' : 'AM');
        out.write(upper ? text : text.toLowerCase());
      case _DecimalPoint():
        var j = i + 1;
        while (j < tokens.length && tokens[j] is _Digit) {
          j++;
        }
        final digits = j - i - 1;
        if (digits > 0) {
          out.write('.${(date.millisecond ~/ math.pow(10, 3 - math.min(digits, 3))).toString().padLeft(digits, '0')}');
          i = j - 1;
        } else {
          out.write('.');
        }
      case _Literal(:final text):
        out.write(text);
      case _Digit(:final kind):
        out.write(kind == '0' ? '0' : '');
      case _Comma():
        out.write(',');
      case _Percent():
        out.write('%');
      case _Slash():
        out.write('/');
      default:
        break;
    }
  }
  return out.toString();
}
