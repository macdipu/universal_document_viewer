/// Spreadsheets: Excel workbooks (.xlsx) and CSV files.
///
/// [SpreadsheetView] shows the sheet a [SpreadsheetController] has loaded,
/// building only the cells on screen, with the file's column widths, frozen
/// panes, merged cells, number formats, borders, conditional formatting and
/// notes.
///
/// To read a workbook's cells without showing them, parse it with
/// [XlsxReader] or [CsvReader] into a [Workbook].
library;

export 'src/common/document_controller.dart';
export 'src/common/document_format.dart';
export 'src/common/document_viewer_strings.dart';
export 'src/common/document_viewer_theme.dart';
export 'src/common/reader_contract.dart';
export 'src/engines/spreadsheet/csv_reader.dart';
export 'src/engines/spreadsheet/number_format.dart';
export 'src/engines/spreadsheet/workbook.dart';
export 'src/engines/spreadsheet/xlsx_reader.dart';
export 'src/spreadsheet/cell_match.dart';
export 'src/spreadsheet/spreadsheet_controller.dart';
export 'src/spreadsheet/spreadsheet_view.dart' show SpreadsheetView;
