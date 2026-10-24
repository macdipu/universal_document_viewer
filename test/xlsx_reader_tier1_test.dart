import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/sheets.dart';
import 'package:universal_document_viewer/testing.dart';

/// Borders, notes, filled formulas and conditional formatting: what a
/// reader needs to see a sheet as its author did.
void main() {
  Worksheet sheetOf(XlsxTestSheet sheet, {List<String> dxfs = const []}) =>
      XlsxReader.read(buildXlsx([sheet], dxfs: dxfs)).sheets.single;

  SheetCell? at(Worksheet sheet, String address) {
    final column = address.codeUnitAt(0) - 65;
    final row = int.parse(address.substring(1)) - 1;
    return row < sheet.rows.length && column < sheet.rows[row].length ? sheet.rows[row][column] : null;
  }

  test('cell borders: style, colour and sides, on blank cells too', () {
    final sheet = sheetOf(const XlsxTestSheet('S', {
      'A1': XlsxTestCell('Total', border: 'medium', borderSides: ['top', 'bottom'], borderColor: 'FF0000'),
      'B2': XlsxTestCell(null, border: 'double', borderSides: ['bottom']),
    }));
    final total = at(sheet, 'A1')!.style.borders;
    expect(total.top?.style, BorderLineStyle.medium);
    expect(total.top?.color, 0xFFFF0000);
    expect(total.bottom?.style, BorderLineStyle.medium);
    expect(total.left, isNull);
    final blank = at(sheet, 'B2');
    expect(blank, isNotNull, reason: 'a bordered blank cell is kept');
    expect(blank!.style.borders.bottom?.style, BorderLineStyle.doubleLine);
    expect(blank.style.borders.bottom?.color, isNull, reason: 'automatic');
  });

  test('notes, with their author, also on cells without a value', () {
    final sheet = sheetOf(const XlsxTestSheet(
      'S',
      {'A1': 5},
      comments: {
        'A1': (author: 'Rina', text: 'Estimate - confirm with finance'),
        'C4': (
          author: 'tc={1D2E}',
          text: '[Threaded comment]\n\nYour version of Excel allows you to read this threaded comment; however, '
              'any edits to it will get removed if the file is opened in a newer version of Excel.\n\n'
              'Comment:\n    Is this final?\nReply:\n    Yes',
        ),
      },
    ));
    expect(sheet.comments[(row: 0, column: 0)]?.text, 'Estimate - confirm with finance');
    expect(sheet.comments[(row: 0, column: 0)]?.author, 'Rina');
    final threaded = sheet.comments[(row: 3, column: 2)]!;
    expect(threaded.text, 'Is this final?\nReply:\nYes');
    expect(threaded.author, isNull);
    expect(sheet.rows.length, greaterThanOrEqualTo(4), reason: "the note's row exists");
  });

  test('a formula filled down shows in each cell with its references moved', () {
    final sheet = sheetOf(const XlsxTestSheet('S', {
      'A1': 1,
      'A2': 2,
      'A3': 3,
      'B1': XlsxTestXml('<f t="shared" ref="B1:B3" si="0">A1*2</f><v>2</v>'),
      'B2': XlsxTestXml('<f t="shared" si="0"/><v>4</v>'),
      'B3': XlsxTestXml('<f t="shared" si="0"/>'),
      'C1': XlsxTestXml('<f t="array" ref="C1">SUM(A1:A3*2)</f><v>12</v>'),
    }));
    expect(at(sheet, 'B1')!.formulaText, '=A1*2');
    expect(at(sheet, 'B2')!.formulaText, '=A2*2');
    expect(at(sheet, 'B2')!.text, '4');
    // No saved result: the cell shows its own formula, not a bare "=".
    expect(at(sheet, 'B3')!.text, '=A3*2');
    expect(at(sheet, 'C1')!.formulaText, '{=SUM(A1:A3*2)}');
    expect(at(sheet, 'A1')!.formulaText, isNull);
  });

  group('conditional formatting', () {
    const red = '<dxf><font><b/><color rgb="FF9C0006"/></font><fill><patternFill><bgColor rgb="FFFFC7CE"/></patternFill></fill></dxf>';
    const green = '<dxf><fill><patternFill><bgColor rgb="FFC6EFCE"/></patternFill></fill></dxf>';
    String rule(String sqref, String body) => '<conditionalFormatting sqref="$sqref">$body</conditionalFormatting>';

    test('cellIs: against a constant and against a cell, with between', () {
      final sheet = sheetOf(
        XlsxTestSheet('S', const {'A1': 50, 'A2': 150, 'A3': 100, 'B1': 120, 'C1': 5, 'C2': 15}, afterSheetData: [
          rule('A1:A3', '<cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan"><formula>100</formula></cfRule>'),
          rule('A1:A3', r'<cfRule type="cellIs" dxfId="1" priority="2" operator="lessThan"><formula>$B$1</formula></cfRule>'),
          rule('C1:C2', '<cfRule type="cellIs" dxfId="1" priority="3" operator="between"><formula>1</formula><formula>10</formula></cfRule>'),
        ].join()),
        dxfs: [red, green],
      );
      expect(at(sheet, 'A2')!.style.fillColor, 0xFFFFC7CE);
      expect(at(sheet, 'A2')!.style.bold, isTrue);
      expect(at(sheet, 'A2')!.style.textColor, 0xFF9C0006);
      expect(at(sheet, 'A1')!.style.fillColor, 0xFFC6EFCE, reason: r'50 < $B$1 (120)');
      expect(at(sheet, 'A3')!.style.fillColor, 0xFFC6EFCE);
      expect(at(sheet, 'C1')!.style.fillColor, 0xFFC6EFCE);
      expect(at(sheet, 'C2')!.style.fillColor, isNull);
    });

    test('earlier priority wins a property; stopIfTrue stops later rules', () {
      final sheet = sheetOf(
        XlsxTestSheet('S', const {'A1': 200, 'A2': 5}, afterSheetData: [
          rule('A1:A2', '<cfRule type="cellIs" dxfId="1" priority="2" operator="greaterThan"><formula>0</formula></cfRule>'),
          rule('A1:A2', '<cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan" stopIfTrue="1"><formula>100</formula></cfRule>'),
        ].join()),
        dxfs: [red, green],
      );
      expect(at(sheet, 'A1')!.style.fillColor, 0xFFFFC7CE);
      expect(at(sheet, 'A2')!.style.fillColor, 0xFFC6EFCE);
    });

    test('text, blanks, top N, above average and duplicates', () {
      final sheet = sheetOf(
        XlsxTestSheet('S', const {
          'A1': 'Overdue', 'A2': 'On track', 'A3': 'overdue soon', //
          'B1': 10, 'B2': 40, 'B3': 30, 'B4': 20,
          'C1': 'x', 'C2': 'y', 'C3': 'X',
          'D1': 'a', 'D3': 'b',
        }, afterSheetData: [
          rule('A1:A3', '<cfRule type="containsText" dxfId="0" priority="1" operator="containsText" text="overdue"/>'),
          rule('B1:B4', '<cfRule type="top10" dxfId="0" priority="2" rank="1"/>'),
          rule('B1:B4', '<cfRule type="aboveAverage" dxfId="1" priority="3"/>'),
          rule('C1:C3', '<cfRule type="duplicateValues" dxfId="0" priority="4"/>'),
          rule('D1:D3', '<cfRule type="containsBlanks" dxfId="1" priority="5"/>'),
        ].join()),
        dxfs: [red, green],
      );
      expect(at(sheet, 'A1')!.style.fillColor, 0xFFFFC7CE);
      expect(at(sheet, 'A2')!.style.fillColor, isNull);
      expect(at(sheet, 'A3')!.style.fillColor, 0xFFFFC7CE);
      expect(at(sheet, 'B2')!.style.fillColor, 0xFFFFC7CE, reason: 'the top 1');
      expect(at(sheet, 'B3')!.style.fillColor, 0xFFC6EFCE, reason: '30 > average 25');
      expect(at(sheet, 'B1')!.style.fillColor, isNull);
      expect(at(sheet, 'C1')!.style.fillColor, 0xFFFFC7CE, reason: 'x and X are duplicates');
      expect(at(sheet, 'C2')!.style.fillColor, isNull);
      expect(at(sheet, 'D2')?.style.fillColor, 0xFFC6EFCE, reason: 'a blank cell gets the fill');
    });

    test('a colour scale and a data bar', () {
      final sheet = sheetOf(XlsxTestSheet('S', const {'A1': 0, 'A2': 50, 'A3': 100}, afterSheetData: [
        rule('A1:A3', '<cfRule type="colorScale" priority="1"><colorScale><cfvo type="min"/><cfvo type="max"/>'
            '<color rgb="FFFFFFFF"/><color rgb="FF000000"/></colorScale></cfRule>'),
        rule('A1:A3', '<cfRule type="dataBar" priority="2"><dataBar><cfvo type="min"/><cfvo type="max"/>'
            '<color rgb="FF638EC6"/></dataBar></cfRule>'),
      ].join()));
      expect(at(sheet, 'A1')!.style.fillColor, 0xFFFFFFFF);
      expect(at(sheet, 'A2')!.style.fillColor, anyOf(0xFF808080, 0xFF7F7F7F));
      expect(at(sheet, 'A3')!.style.fillColor, 0xFF000000);
      expect(at(sheet, 'A1')!.dataBar!.fraction, closeTo(0.1, 1e-9));
      expect(at(sheet, 'A2')!.dataBar!.fraction, closeTo(0.5, 1e-9));
      expect(at(sheet, 'A3')!.dataBar!.fraction, closeTo(0.9, 1e-9));
      expect(at(sheet, 'A3')!.dataBar!.color, 0xFF638EC6);
    });

    test('rules it can\'t evaluate (expressions) change nothing', () {
      final sheet = sheetOf(
        XlsxTestSheet('S', const {'A1': 1}, afterSheetData: rule('A1', r'<cfRule type="expression" dxfId="0" priority="1"><formula>$A1&gt;0</formula></cfRule>')),
        dxfs: [red],
      );
      expect(at(sheet, 'A1')!.style.fillColor, isNull);
    });
  });
}
