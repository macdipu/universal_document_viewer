/// A single cell match from a [SpreadsheetController]'s search.
class CellMatch {
  /// Zero-based row index in the sheet.
  final int row;

  /// Zero-based column index in the sheet.
  final int column;

  /// Creates a match at [row], [column].
  const CellMatch({required this.row, required this.column});
}
