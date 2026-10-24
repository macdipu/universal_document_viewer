import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/sheets.dart';

void main() {
  String fmt(String code, num value, {bool date1904 = false}) => NumberFormat(code).format(value, date1904: date1904);

  test('General', () {
    expect(fmt('General', 0), '0');
    expect(fmt('General', 42), '42');
    expect(fmt('General', -7.5), '-7.5');
    expect(fmt('General', 0.1 + 0.2), '0.3');
    expect(fmt('General', 3.14159265358979), '3.141592654');
    expect(fmt('General', 123456789012), '1.23457E+11');
    expect(fmt('General', 0.0000000001234), '1.234E-10');
    expect(fmt('General', 2200.0), '2200');
  });

  test('digit placeholders, decimals and grouping', () {
    expect(fmt('0', 3.6), '4');
    expect(fmt('0.00', 3.14159), '3.14');
    expect(fmt('0.00', -3.14159), '-3.14');
    expect(fmt('#,##0', 1234567), '1,234,567');
    expect(fmt('#,##0.00', 1234.5), '1,234.50');
    expect(fmt('#,##0.00', 0.5), '0.50');
    expect(fmt('#.##', 0.5), '.5');
    expect(fmt('0.0#', 1.5), '1.5');
    expect(fmt('0.0#', 1.567), '1.57');
    expect(fmt('000', 7), '007');
    expect(fmt('#,##0,', 1234567), '1,235');
    expect(fmt('0.0,,', 1234567), '1.2');
    expect(fmt('000-00-0000', 123456789), '123-45-6789');
  });

  test('percent and scientific', () {
    expect(fmt('0%', 0.256), '26%');
    expect(fmt('0.00%', 0.256), '25.60%');
    expect(fmt('0.00E+00', 12345), '1.23E+04');
    expect(fmt('0.00E+00', 0.000123), '1.23E-04');
    expect(fmt('##0.0E+0', 12345), '12.3E+3');
  });

  test('sections, literals, colours and currency', () {
    const accounting = r'$#,##0.00_);[Red]($#,##0.00)';
    expect(fmt(accounting, 1234.5), r'$1,234.50');
    expect(fmt(accounting, -1234.5), r'($1,234.50)');
    expect(fmt('0;-0;"zero"', 0), 'zero');
    expect(fmt('#,##0 "kg"', 1500), '1,500 kg');
    expect(fmt(r'[$€-407] #,##0.00', 9.5), '€ 9.50');
    expect(fmt('[>=100]"big";"small"', 150), 'big');
    expect(fmt('[>=100]"big";"small"', 5), 'small');
    expect(fmt(NumberFormat.builtIn(44)!.code, 0), r'$ -');
    expect(fmt(NumberFormat.builtIn(43)!.code, 1234.5), '1,234.50');
  });

  test('fractions', () {
    expect(fmt('# ?/?', 1.5), '1 1/2');
    expect(fmt('# ??/??', 3.14159), '3 14/99');
    expect(fmt('?/8', 0.375), '3/8');
    expect(fmt('# ?/?', 2), '2');
  });

  test('dates and times (1900 system)', () {
    // 45306 = 2024-01-15 (a Monday).
    expect(fmt('m/d/yyyy', 45306), '1/15/2024');
    expect(fmt('yyyy-mm-dd', 45306), '2024-01-15');
    expect(fmt('d-mmm-yy', 45306), '15-Jan-24');
    expect(fmt('dddd, mmmm d, yyyy', 45306), 'Monday, January 15, 2024');
    expect(fmt('mmmmm', 45306), 'J');
    expect(fmt('h:mm AM/PM', 45306.75), '6:00 PM');
    expect(fmt('h:mm:ss', 0.5 + 1 / 86400 * 5), '12:00:05');
    expect(fmt('hh:mm', 45306.0416666667), '01:00');
    expect(fmt('m/d/yyyy h:mm', 45306.5), '1/15/2024 12:00');
    expect(fmt('[h]:mm:ss', 1.5), '36:00:00');
    expect(fmt('mm:ss.0', 0.00001), '00:00.9');
    expect(fmt('yyyy-mm-dd', 1), '1900-01-01');
    expect(fmt('yyyy-mm-dd', 60), '1900-02-29');
    expect(fmt('yyyy-mm-dd', 61), '1900-03-01');
  });

  test('dates in the 1904 system', () {
    expect(fmt('yyyy-mm-dd', 0, date1904: true), '1904-01-01');
    expect(fmt('yyyy-mm-dd', 43844, date1904: true), '2024-01-15');
  });

  test('built-in ids', () {
    expect(NumberFormat.builtIn(0)!.isGeneral, isTrue);
    expect(NumberFormat.builtIn(14)!.isDate, isTrue);
    expect(NumberFormat.builtIn(4)!.isDate, isFalse);
    expect(NumberFormat.builtIn(164), isNull);
  });
}
