# universal_document_viewer example

The package's own test app: sample documents in every format universal_document_viewer reads, opened with the ready-made `DocumentViewer` and with the per-format readers, plus any file you pick.

## What it shows

- **Home:** the bundled samples and the files you opened, each with a `DocumentThumbnails` preview of the page it resumes on.
- **DocumentViewer** (tap a row): any format. A password-protected PDF asks for its password (`locked.pdf`: `open`).
- **Word reader** (row menu on `report.docx`): `WordDocumentController` and `WordDocumentView`, with search and the continuous/print layout switch.
- **Sheet reader** (row menu on `sales.xlsx` or `contacts.csv`): `SpreadsheetController` and `SheetGrid`, with sheet tabs, search, `showGoToDialog` and "Freeze header row". `sales.xlsx` has borders, conditional formatting (highlights, a data bar, a colour scale), notes and formulas.
- **Reading positions:** every reader reports where you are, and the app saves the JSON-safe maps to disk. Reopening a document, or its thumbnail, resumes there. "Forget reading positions" in the app bar resets them.

## Run it

```sh
flutter run
```

Android, iOS and macOS projects are included; add others with `flutter create --platforms=windows,linux .`. The first build downloads PDFium for the target platform (see the package README).

## Test on a device

`integration_test/samples_test.dart` opens every sample on a real device or emulator (native PDFium, the background parsing isolates, real fonts), types the PDF password, searches the Word file, uses go to and freeze in the workbook, and renders every thumbnail:

```sh
flutter test integration_test -d <device id>
```

## Samples

`assets/samples` is built by `tool/make_samples.py` (`pip install reportlab openpyxl`, then `python3 tool/make_samples.py`). `report.docx` is the package's own Word test document, and `deck.pptx` was built with the package's `buildPptx` (`package:universal_document_viewer/testing.dart`).
