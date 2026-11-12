import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/testing.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

/// CR-EXCEL-READER-AUDIT S4: file types, password-protected workbooks,
/// hidden-sheet names, content the reader doesn't draw, range links.
void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('sheet-gaps-'));
  tearDown(() => temp.delete(recursive: true));

  /// An OLE2 compound file header, padded, optionally naming an
  /// `EncryptedPackage` stream as a directory entry does (UTF-16LE).
  Uint8List ole2({required bool encrypted}) {
    final bytes = BytesBuilder()
      ..add([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
      ..add(List.filled(1024, 0));
    if (encrypted) {
      bytes.add([
        for (final unit in 'EncryptedPackage'.codeUnits) ...[unit, 0],
      ]);
    } else {
      bytes.add([
        for (final unit in 'Workbook'.codeUnits) ...[unit, 0],
      ]);
    }
    bytes.add(List.filled(512, 0));
    return bytes.toBytes();
  }

  /// A workbook with a VBA project part, as Excel saves an `.xlsm`.
  Uint8List macroWorkbook() {
    final archive = ZipDecoder().decodeBytes(
      buildXlsx(const [
        XlsxTestSheet('Macros', {'A1': 'Total', 'B1': 42}),
      ]),
    );
    final out = Archive();
    for (final file in archive) {
      if (file.name == 'xl/_rels/workbook.xml.rels') {
        final rels = utf8
            .decode(file.content as List<int>)
            .replaceFirst(
              '</Relationships>',
              '<Relationship Id="rIdVba" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" '
                  'Target="vbaProject.bin"/></Relationships>',
            );
        out.addFile(ArchiveFile.bytes(file.name, utf8.encode(rels)));
      } else {
        out.addFile(ArchiveFile.bytes(file.name, file.content as List<int>));
      }
    }
    out.addFile(ArchiveFile.bytes('xl/vbaProject.bin', ole2(encrypted: false)));
    return Uint8List.fromList(ZipEncoder().encodeBytes(out));
  }

  group('file types', () {
    test('.xlsm reads as a workbook and .tsv as delimited text', () {
      expect(DocumentFormat.fromPath('/d/Budget.XLSM'), DocumentFormat.excel);
      expect(DocumentFormat.fromPath('/d/export.tsv'), DocumentFormat.csv);
      expect(DocumentFormat.supportedExtensions, containsAll(['xlsm', 'tsv']));
      expect(DocumentFormat.extensionForMimeType('application/vnd.ms-excel.sheet.macroEnabled.12'), 'xlsm');
      expect(DocumentFormat.extensionForMimeType('text/tab-separated-values'), 'tsv');
      expect(DocumentFormat.fromExtension('xls'), isNull, reason: 'legacy .xls stays unsupported');
    });

    test('an .xlsm opens read-only; its macro part is never read', () async {
      final file = File('${temp.path}/macros.xlsm')..writeAsBytesSync(macroWorkbook());
      final sheet = SpreadsheetController();
      await sheet.loadFile(file.path);
      expect(sheet.error, isNull);
      expect(sheet.sheetNames, ['Macros']);
      expect(sheet.currentRows[0][1]?.text, '42');
    });

    test('a .tsv splits on tabs even when its first line has more commas', () async {
      final file = File('${temp.path}/data.tsv')..writeAsStringSync('a,b,c\tsecond\n1,2\t3\n');
      final sheet = SpreadsheetController();
      await sheet.loadFile(file.path);
      expect(sheet.error, isNull);
      expect(sheet.currentRows[0].map((c) => c?.text), ['a,b,c', 'second']);
      expect(sheet.currentRows[1].map((c) => c?.text), ['1,2', '3']);
    });

    test('a .csv still detects its delimiter', () async {
      final file = File('${temp.path}/data.csv')..writeAsStringSync('a;b;c\n1;2;3\n');
      final sheet = SpreadsheetController();
      await sheet.loadFile(file.path);
      expect(sheet.currentRows[0].length, 3);
    });
  });

  group('password-protected workbooks', () {
    test('the guard tells an encrypted package from other OLE2 files', () {
      expect(ZipSafetyGuard.isEncryptedOfficeFile(ole2(encrypted: true)), isTrue);
      expect(ZipSafetyGuard.isEncryptedOfficeFile(ole2(encrypted: false)), isFalse);
      expect(ZipSafetyGuard.isEncryptedOfficeFile(buildXlsx(const [XlsxTestSheet('S', {})])), isFalse);
      expect(ZipSafetyGuard.isEncryptedOfficeFile(Uint8List(8)), isFalse);
    });

    test('an encrypted .xlsx fails as password protected, not damaged', () async {
      final file = File('${temp.path}/locked.xlsx')..writeAsBytesSync(ole2(encrypted: true));
      final sheet = SpreadsheetController();
      await sheet.loadFile(file.path);
      expect(sheet.error, DocumentLoadError.passwordRequired);
    });

    test('an encrypted workbook without an extension is recognised too', () async {
      final sheet = SpreadsheetController();
      await sheet.loadBytes(ole2(encrypted: true));
      expect(sheet.error, DocumentLoadError.passwordRequired);
    });

    test('a legacy .xls renamed .xlsx is still damaged, not locked', () async {
      final file = File('${temp.path}/old.xlsx')..writeAsBytesSync(ole2(encrypted: false));
      final sheet = SpreadsheetController();
      await sheet.loadFile(file.path);
      expect(sheet.error, DocumentLoadError.corrupted);
    });
  });

  group('hidden sheets', () {
    test('names the hidden ones, but not very hidden ones', () async {
      final sheet = SpreadsheetController();
      await sheet.loadBytes(
        buildXlsx(const [
          XlsxTestSheet('Shown', {'A1': 1}),
          XlsxTestSheet('Rates', {'A1': 2}, state: 'hidden'),
          XlsxTestSheet('Internal', {'A1': 3}, state: 'veryHidden'),
        ]),
      );
      expect(sheet.sheetNames, ['Shown']);
      expect(sheet.hiddenSheetNames, ['Rates']);
    });

    test('when every sheet is hidden they are shown, and none is listed as hidden', () async {
      final sheet = SpreadsheetController();
      await sheet.loadBytes(
        buildXlsx(const [
          XlsxTestSheet('Only', {'A1': 1}, state: 'hidden'),
        ]),
      );
      expect(sheet.sheetNames, ['Only']);
      expect(sheet.hiddenSheetNames, isEmpty);
    });

    test('CSV has none', () async {
      final sheet = SpreadsheetController();
      await sheet.loadBytes(Uint8List.fromList(utf8.encode('a,b\n')));
      expect(sheet.hiddenSheetNames, isEmpty);
    });
  });

  group('content not shown', () {
    Worksheet read(String afterSheetData) => XlsxReader.read(
      buildXlsx([
        XlsxTestSheet('S', const {'A1': 1, 'A2': 2}, afterSheetData: afterSheetData),
      ]),
    ).sheets.single;

    test('a plain sheet reports nothing', () => expect(read('').unshown, isEmpty));

    test('drawings, tables, validation and sparklines are reported', () {
      final sheet = read(
        '<dataValidations count="1"><dataValidation type="list" sqref="A1"><formula1>"a,b"</formula1></dataValidation></dataValidations>'
        '<drawing r:id="rId5" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>'
        '<tableParts count="1"><tablePart r:id="rId6" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></tableParts>'
        '<extLst><ext><x14:sparklineGroups xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">'
        '<x14:sparklineGroup/></x14:sparklineGroups></ext></extLst>',
      );
      expect(sheet.unshown, {
        UnshownContent.dataValidation,
        UnshownContent.drawings,
        UnshownContent.tables,
        UnshownContent.sparklines,
      });
    });

    test('only rules the reader cannot evaluate are reported', () {
      final evaluated = read(
        '<conditionalFormatting sqref="A1:A2"><cfRule type="cellIs" operator="greaterThan" priority="1">'
        '<formula>1</formula></cfRule></conditionalFormatting>',
      );
      expect(evaluated.unshown, isEmpty);
      final formula = read(
        '<conditionalFormatting sqref="A1:A2"><cfRule type="expression" priority="1">'
        '<formula>MOD(ROW(),2)=0</formula></cfRule></conditionalFormatting>',
      );
      expect(formula.unshown, {UnshownContent.conditionalFormatting});
    });

    test('a comment\'s VML drawing is not mistaken for a picture', () {
      final sheet = read(
        '<legacyDrawing r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>',
      );
      expect(sheet.unshown, isEmpty);
    });
  });

  group('range hyperlinks', () {
    test('every cell of a linked range carries the link', () {
      final sheet = XlsxReader.read(
        buildXlsx(const [
          XlsxTestSheet('S', {
            'A1': 'a',
            'B2': 'b',
          }, afterSheetData: '<hyperlinks><hyperlink ref="A1:B2" location="Other!A1"/></hyperlinks>'),
        ]),
      ).sheets.single;
      for (final (r, c) in [(0, 0), (0, 1), (1, 0), (1, 1)]) {
        expect(sheet.hyperlinks[(row: r, column: c)], '#Other!A1', reason: '($r, $c)');
      }
      expect(sheet.hyperlinks.length, 4);
    });

    test('a whole-column link stops at a budget', () {
      final sheet = XlsxReader.read(
        buildXlsx(const [
          XlsxTestSheet('S', {
            'A1': 'a',
          }, afterSheetData: '<hyperlinks><hyperlink ref="A1:A1048576" location="S!B1"/></hyperlinks>'),
        ]),
      ).sheets.single;
      expect(sheet.hyperlinks.length, lessThanOrEqualTo(100000));
      expect(sheet.hyperlinks[(row: 0, column: 0)], '#S!B1');
    });

    test('a link on one cell is unchanged', () {
      final sheet = XlsxReader.read(
        buildXlsx(const [
          XlsxTestSheet('S', {
            'C3': 'x',
          }, afterSheetData: '<hyperlinks><hyperlink ref="C3" location="S!A1"/></hyperlinks>'),
        ]),
      ).sheets.single;
      expect(sheet.hyperlinks, {(row: 2, column: 2): '#S!A1'});
    });
  });
}
