/// Conventions every universal_document_viewer reader follows, so an app can treat
/// them alike.
///
/// - **Controllers** are plain `ChangeNotifier`s: no state-management
///   package, no storage. The app decides where positions and favourites
///   live.
/// - **Positions** are opaque key/value maps ([ReadingPosition]). A reader
///   takes an `initialPosition` and reports changes through
///   `onPositionChanged`; the app stores the map as-is. The keys
///   ([PositionKeys]) match what OpenReader has always stored, so saved
///   positions keep working.
/// - **Load failures** are typed ([DocumentLoadError]); the wording is the
///   app's.
library;

/// A reader's saved place in a document, as plain JSON-safe values.
typedef ReadingPosition = Map<String, Object?>;

/// Keys used in [ReadingPosition] maps, per reader.
abstract final class PositionKeys {
  // PDF
  static const pageNumber = 'page_number';
  static const pageCount = 'page_count';
  static const zoom = 'zoom';
  static const viewMode = 'view_mode'; // also Word: continuous/paged
  // Word, Text
  static const scrollOffset = 'scroll_offset';

  /// Word: the number of the paragraph at the top of the view, in the
  /// reading order of `WordDocumentLayout` (for a resumed-page thumbnail;
  /// the offset is what the reader restores).
  static const paragraph = 'paragraph';

  /// Text: the zero-based line at the top of the view.
  static const line = 'line';
  // Excel, CSV
  static const sheetIndex = 'sheet_index';
  static const verticalOffset = 'vertical_offset';
  static const horizontalOffset = 'horizontal_offset';
  static const row = 'row';
  static const column = 'column';

  /// Excel, CSV: the reader froze the header row itself (`true`), for a
  /// sheet whose file froze none.
  static const freezeTopRow = 'freeze_top_row';
  // PowerPoint
  static const slideIndex = 'slide_index';
  static const slideCount = 'slide_count';
}

/// Why a document couldn't be opened.
enum DocumentLoadError {
  /// Bigger than the reader will safely load (file size, or a ZIP whose
  /// declared contents exceed `ZipSafetyGuard`'s ceilings).
  tooLarge,

  /// Not a well-formed file of its type: truncated, damaged, or (for
  /// Office files) an encrypted/OLE2-wrapped package.
  corrupted,

  /// Encrypted PDF and no (or a wrong) password.
  passwordRequired,

  /// Not a format the kit reads.
  unsupported,
}
