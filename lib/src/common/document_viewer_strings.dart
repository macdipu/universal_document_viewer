import 'package:flutter/widgets.dart';

import 'document_controller.dart';
import 'reader_contract.dart';

/// The text the package's widgets show: messages, labels, tooltips and
/// screen-reader descriptions. English by default.
///
/// To translate or reword it, subclass and override what you need, then
/// put it above the viewers with [DocumentViewerStringsScope]:
///
/// ```dart
/// class GermanStrings extends DocumentViewerStrings {
///   const GermanStrings();
///   @override
///   String get noMatches => 'Keine Treffer';
/// }
///
/// DocumentViewerStringsScope(strings: const GermanStrings(), child: app)
/// ```
class DocumentViewerStrings {
  /// The English strings.
  const DocumentViewerStrings();

  /// The strings from the nearest [DocumentViewerStringsScope], or English.
  static DocumentViewerStrings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DocumentViewerStringsScope>()?.strings ??
      const DocumentViewerStrings();

  // ---- Loading

  /// Why a document couldn't be opened.
  String loadError(DocumentLoadError error) => switch (error) {
    DocumentLoadError.tooLarge => 'This document is too large to open.',
    DocumentLoadError.corrupted => 'This document may be damaged or incomplete.',
    DocumentLoadError.passwordRequired => 'This document is password protected.',
    DocumentLoadError.unsupported => 'This file type is not supported.',
  };

  // ---- Where the reader is

  /// "Page 3 of 12", "Row 40 of 900", "42%".
  String location(DocumentLocation location) => switch (location.unit) {
    DocumentUnit.page => 'Page ${location.current} of ${location.count}',
    DocumentUnit.slide => 'Slide ${location.current} of ${location.count}',
    DocumentUnit.row => 'Row ${location.current} of ${location.count}',
    DocumentUnit.line => 'Line ${location.current} of ${location.count}',
    DocumentUnit.percent => '${location.current}%',
  };

  /// Screen-reader label for page [number] (from 1).
  String page(int number) => 'Page $number';

  /// Tooltip: back one page, slide, row or line.
  String get previous => 'Previous';

  /// Tooltip: on one page, slide, row or line.
  String get next => 'Next';

  /// Tooltip: zoom out.
  String get zoomOut => 'Zoom out';

  /// Tooltip: zoom in.
  String get zoomIn => 'Zoom in';

  // ---- Search

  /// Tooltip, and the search field's hint.
  String get search => 'Search';

  /// Tooltip: close the search.
  String get closeSearch => 'Close search';

  /// Tooltip: the previous match.
  String get previousMatch => 'Previous match';

  /// Tooltip: the next match.
  String get nextMatch => 'Next match';

  /// While a background search (PDF) has found nothing yet.
  String get searching => 'Searching…';

  /// A search with no matches.
  String get noMatches => 'No matches';

  /// A search in a PDF with no text to search (a scanned document).
  String get noSearchableText => 'No searchable text found.';

  /// Which match is current: "3 of 12".
  String matchOf(int current, int count) => '$current of $count';

  /// The search status line for [state]: empty when there's no search.
  String searchStatus(DocumentSearchState state) {
    if (!state.isActive) return '';
    if (state.matchCount == 0) {
      if (state.isSearching) return searching;
      return state.hasSearchableText ? noMatches : noSearchableText;
    }
    return matchOf(state.currentMatch + 1, state.matchCount);
  }

  // ---- Word

  /// Heading above a document's footnotes and endnotes.
  String get notes => 'Notes';

  /// Screen-reader label for a note mark.
  String noteMark(String label) => 'Note $label';

  // ---- Slides

  /// Shown on a slide with nothing to show.
  String emptySlide(int number) => 'Slide $number has no text or pictures to show.';

  // ---- Spreadsheets

  /// Shown instead of a sheet with no cells.
  String get emptySheet => 'No data to display';

  /// A column, by its letters: "Column C".
  String column(String letters) => 'Column $letters';

  /// A row, by its number: "Row 12".
  String row(int number) => 'Row $number';

  /// The title of a cell's details: "Cell B3".
  String cell(String address) => 'Cell $address';

  /// A formula cell saved without its result.
  String get formulaWithoutResult => 'No saved result: the file was saved without calculating this formula.';

  /// Label above a cell's formula.
  String get formula => 'Formula';

  /// Tooltip: copy a cell's formula.
  String get copyFormula => 'Copy formula';

  /// Label above a cell's note; [author] when the note has one.
  String note({String? author}) => author == null ? 'Note' : 'Note from $author';

  /// Button: open a cell's link.
  String get openLink => 'Open link';

  /// Button: copy.
  String get copy => 'Copy';

  /// A selection's count of values.
  String count(int count) => 'Count $count';

  /// A selection's sum.
  String sum(String sum) => 'Sum $sum';

  /// A selection's average.
  String average(String average) => 'Avg $average';

  /// Tooltip: copy a selected row or column, named by [what] ("Row 3").
  String copySelection(String what) => 'Copy ${what.toLowerCase()}';

  /// Tooltip: clear the selected row or column.
  String get clearSelection => 'Clear selection';
}

/// Gives the package's widgets below it [strings] instead of English.
class DocumentViewerStringsScope extends InheritedWidget {
  /// Provides [strings] to [child]'s viewers.
  const DocumentViewerStringsScope({super.key, required this.strings, required super.child});

  /// The text the viewers show.
  final DocumentViewerStrings strings;

  @override
  bool updateShouldNotify(DocumentViewerStringsScope oldWidget) => strings != oldWidget.strings;
}
