/// Moves a formula's relative references as Excel does when a formula is
/// filled across cells: [formula] written for one cell, as it reads in a
/// cell [rows] down and [columns] across. `$`-anchored parts stay put; a
/// reference moved off the sheet becomes `#REF!`.
///
/// Excel stores a formula filled down a column once (a "shared formula",
/// §18.3.1.40); this gives each cell its own text. References are found
/// lexically: text in double quotes and quoted sheet names are left alone,
/// and a name that is also a cell address (`LOG10(`, `Q1!`, `Tbl1[`) is
/// told apart by what follows it.
String shiftFormula(String formula, int rows, int columns) {
  if (rows == 0 && columns == 0) return formula;
  final out = StringBuffer();
  var i = 0;
  while (i < formula.length) {
    final char = formula[i];
    // A structured reference (`Sales[Q1]`, `[@Q2]`, `Tbl[[#This Row],[A]]`)
    // names table columns, not cells.
    if (char == '[') {
      final end = _bracketEnd(formula, i);
      out.write(formula.substring(i, end));
      i = end;
      continue;
    }
    if (char == '"' || char == "'") {
      final end = _quotedEnd(formula, i, char);
      out.write(formula.substring(i, end));
      i = end;
      continue;
    }
    if (i == 0 || !_isNameChar(formula.codeUnitAt(i - 1))) {
      final match = _reference.matchAsPrefix(formula, i);
      if (match != null && _endsReference(formula, match.end)) {
        final shifted = _shift(match, rows, columns);
        if (shifted != null) {
          out.write(shifted);
          i = match.end;
          continue;
        }
      }
    }
    out.write(char);
    i++;
  }
  return out.toString();
}

/// A cell (`$B$2`), a column range (`A:C`) or a row range (`2:5`).
final _reference = RegExp(
  r'(\$?)([A-Za-z]{1,3})(\$?)(\d+)(?![A-Za-z0-9_])'
  r'|(\$?)([A-Za-z]{1,3}):(\$?)([A-Za-z]{1,3})(?![A-Za-z0-9_])'
  r'|(\$?)(\d+):(\$?)(\d+)(?![A-Za-z0-9_])',
);

const _maxRow = 1048576;
const _maxColumn = 16384;

/// The index just past a quoted run starting at [start]; a doubled quote
/// inside is an escaped one.
int _quotedEnd(String text, int start, String quote) {
  var i = start + 1;
  while (i < text.length) {
    if (text[i] == quote) {
      if (i + 1 < text.length && text[i + 1] == quote) {
        i += 2;
        continue;
      }
      return i + 1;
    }
    i++;
  }
  return text.length;
}

/// The index just past the bracketed run starting at [start], nested
/// brackets included; `'` escapes a bracket inside a column name.
int _bracketEnd(String text, int start) {
  var depth = 0;
  var i = start;
  while (i < text.length) {
    final char = text[i];
    if (char == "'") {
      i += 2;
      continue;
    }
    if (char == '[') depth++;
    if (char == ']' && --depth == 0) return i + 1;
    i++;
  }
  return text.length;
}

bool _isNameChar(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || // 0-9
    (unit >= 0x41 && unit <= 0x5A) || // A-Z
    (unit >= 0x61 && unit <= 0x7A) || // a-z
    unit == 0x5F || // _
    unit == 0x2E; // .

/// A function call (`LOG10(`), a sheet name (`Q1!`) or a table (`Tbl1[`)
/// isn't a reference.
bool _endsReference(String text, int end) {
  if (end >= text.length) return true;
  final next = text[end];
  return next != '(' && next != '!' && next != '[';
}

String? _shift(Match m, int rows, int columns) {
  if (m.group(2) != null) {
    final column = _columnNumber(m.group(2)!);
    final row = int.parse(m.group(4)!);
    if (column > _maxColumn || row < 1 || row > _maxRow) return null;
    final newColumn = m.group(1)!.isEmpty ? column + columns : column;
    final newRow = m.group(3)!.isEmpty ? row + rows : row;
    if (newColumn < 1 || newColumn > _maxColumn || newRow < 1 || newRow > _maxRow) return '#REF!';
    return '${m.group(1)}${_columnLetters(newColumn)}${m.group(3)}$newRow';
  }
  if (m.group(6) != null) {
    final first = _columnNumber(m.group(6)!);
    final last = _columnNumber(m.group(8)!);
    if (first > _maxColumn || last > _maxColumn) return null;
    final a = m.group(5)!.isEmpty ? first + columns : first;
    final b = m.group(7)!.isEmpty ? last + columns : last;
    if (a < 1 || b < 1 || a > _maxColumn || b > _maxColumn) return '#REF!';
    return '${m.group(5)}${_columnLetters(a)}:${m.group(7)}${_columnLetters(b)}';
  }
  final first = int.parse(m.group(10)!);
  final last = int.parse(m.group(12)!);
  final a = m.group(9)!.isEmpty ? first + rows : first;
  final b = m.group(11)!.isEmpty ? last + rows : last;
  if (a < 1 || b < 1 || a > _maxRow || b > _maxRow) return '#REF!';
  return '${m.group(9)}$a:${m.group(11)}$b';
}

/// `A` -> 1, `XFD` -> 16384.
int _columnNumber(String letters) {
  var n = 0;
  for (final unit in letters.toUpperCase().codeUnits) {
    n = n * 26 + (unit - 0x40);
  }
  return n;
}

String _columnLetters(int number) {
  var n = number;
  var letters = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    letters = String.fromCharCode(0x41 + rem) + letters;
    n = (n - 1) ~/ 26;
  }
  return letters;
}
