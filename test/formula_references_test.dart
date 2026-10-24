import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/src/engines/sheets/formula_references.dart';

void main() {
  test('moves relative references, keeps anchored parts', () {
    expect(shiftFormula('A2*2', 1, 0), 'A3*2');
    expect(shiftFormula(r'SUM(B2:B9)/$C$1', 3, 1), r'SUM(C5:C12)/$C$1');
    expect(shiftFormula(r'$A2+A$2', 2, 2), r'$A4+C$2');
    expect(shiftFormula('SUM(A:A)+SUM(2:3)', 1, 1), 'SUM(B:B)+SUM(3:4)');
  });

  test('leaves text, sheet names, functions and tables alone', () {
    expect(shiftFormula('IF(A1>0,"B2 ok",LOG10(A1))', 1, 0), 'IF(A2>0,"B2 ok",LOG10(A2))');
    expect(shiftFormula("'Q1 Data'!B2+Q1!C3", 1, 0), "'Q1 Data'!B3+Q1!C4");
    expect(shiftFormula('SUM(Tbl1[Amount])+A1', 0, 1), 'SUM(Tbl1[Amount])+B1');
    expect(shiftFormula('A1*1E5+1.5', 1, 0), 'A2*1E5+1.5');
  });

  test('a reference moved off the sheet is #REF!', () {
    expect(shiftFormula('A1+B2', -1, 0), '#REF!+B1');
    expect(shiftFormula('A1', 0, 0), 'A1');
  });
}
