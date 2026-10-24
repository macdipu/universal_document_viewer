import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';

void main() {
  test('maps extensions with or without a dot, in any case', () {
    expect(DocumentFormat.fromExtension('PDF'), DocumentFormat.pdf);
    expect(DocumentFormat.fromExtension('.docx'), DocumentFormat.word);
    expect(DocumentFormat.fromExtension('md'), DocumentFormat.text);
  });

  test('legacy binary Office formats are not supported', () {
    for (final legacy in ['doc', 'xls', 'ppt']) {
      expect(DocumentFormat.fromExtension(legacy), isNull, reason: legacy);
    }
  });

  test('detects from a path, ignoring folders and dotfiles', () {
    expect(DocumentFormat.fromPath('/storage/Download/deck.final.pptx'), DocumentFormat.powerpoint);
    expect(DocumentFormat.fromPath(r'C:\Users\me\Sheet.XLSX'), DocumentFormat.excel);
    expect(DocumentFormat.fromPath('/home/me/.csv'), isNull);
    expect(DocumentFormat.fromPath('/home/me/notes'), isNull);
  });

  test('maps a shared file\'s MIME type to an extension', () {
    expect(DocumentFormat.extensionForMimeType('application/vnd.openxmlformats-officedocument.presentationml.presentation'), 'pptx');
    expect(DocumentFormat.extensionForMimeType('TEXT/CSV'), 'csv');
    expect(DocumentFormat.extensionForMimeType('application/msword'), isNull);
  });
}
