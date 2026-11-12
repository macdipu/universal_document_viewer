import 'package:flutter/foundation.dart' show immutable;

/// A single cell match from a [SpreadsheetController]'s search.
class CellMatch {
  /// Zero-based row index in the sheet.
  final int row;

  /// Zero-based column index in the sheet.
  final int column;

  /// The index of the sheet the match is on, among the controller's
  /// `sheetNames`; null for "the sheet on screen". Search results always
  /// set it.
  final int? sheet;

  /// Creates a match at [row], [column], on [sheet] if given.
  const CellMatch({required this.row, required this.column, this.sheet});
}

/// How [SpreadsheetController.search] matches cells, as Excel's Find
/// options do.
@immutable
class SheetSearchOptions {
  /// Creates options; the defaults match any case, part of a cell, in the
  /// shown values of the sheet on screen.
  const SheetSearchOptions({
    this.matchCase = false,
    this.wholeCell = false,
    this.inFormulas = false,
    this.allSheets = false,
  });

  /// Upper and lower case must match.
  final bool matchCase;

  /// The whole cell must equal the query, not just contain it.
  final bool wholeCell;

  /// Formula cells are matched by their formula (`=SUM(A1:A3)`) instead
  /// of the value they show (Excel's "Look in: Formulas").
  final bool inFormulas;

  /// Every sheet is searched, not just the one on screen.
  final bool allSheets;

  /// A copy with the given options changed.
  SheetSearchOptions copyWith({bool? matchCase, bool? wholeCell, bool? inFormulas, bool? allSheets}) =>
      SheetSearchOptions(
        matchCase: matchCase ?? this.matchCase,
        wholeCell: wholeCell ?? this.wholeCell,
        inFormulas: inFormulas ?? this.inFormulas,
        allSheets: allSheets ?? this.allSheets,
      );

  @override
  bool operator ==(Object other) =>
      other is SheetSearchOptions &&
      other.matchCase == matchCase &&
      other.wholeCell == wholeCell &&
      other.inFormulas == inFormulas &&
      other.allSheets == allSheets;

  @override
  int get hashCode => Object.hash(matchCase, wholeCell, inFormulas, allSheets);
}
