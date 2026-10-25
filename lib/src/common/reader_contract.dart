/// Conventions every universal_document_viewer reader follows, so an app can treat
/// them alike.
///
/// - **Controllers** are plain `ChangeNotifier`s: no state-management
///   package, no storage. The app decides where positions and favourites
///   live.
/// - **Positions** are opaque key/value maps ([ReadingPosition]). A reader
///   takes an `initialPosition` and reports changes through
///   `onPositionChanged`; the app stores the map as-is. The keys
///   ([PositionKeys]) are stable across versions, so saved positions keep
///   working.
/// - **Load failures** are typed ([DocumentLoadError]); the wording is the
///   app's.
library;

/// A reader's saved place in a document, as plain JSON-safe values.
typedef ReadingPosition = Map<String, Object?>;

/// Keys used in [ReadingPosition] maps, per reader.
abstract final class PositionKeys {
  /// PDF: the page on screen, from 1 (an `int`).
  static const pageNumber = 'page_number';

  /// PDF: the document's page count when the position was saved (an
  /// `int`); absent until the document has loaded.
  static const pageCount = 'page_count';

  /// PDF and Word: the layout, as the `name` of the reader's view-mode enum
  /// (`PdfViewMode`: `continuous`/`horizontal`; `WordViewMode`:
  /// `continuous`/`paged`).
  static const viewMode = 'view_mode';

  /// Word and Text: the vertical scroll offset, in logical pixels; this is
  /// what those readers restore.
  static const scrollOffset = 'scroll_offset';

  /// Word: the number of the paragraph at the top of the view, in the
  /// reading order of `WordDocumentLayout` (for a resumed-page thumbnail;
  /// the offset is what the reader restores).
  static const paragraph = 'paragraph';

  /// Text: the zero-based line at the top of the view.
  static const line = 'line';

  /// Excel, CSV: the active sheet, from 0 (an `int`).
  static const sheetIndex = 'sheet_index';

  /// Excel, CSV: the vertical scroll offset at zoom 1, in logical pixels.
  static const verticalOffset = 'vertical_offset';

  /// Excel, CSV: the horizontal scroll offset at zoom 1, in logical pixels.
  static const horizontalOffset = 'horizontal_offset';

  /// Excel, CSV: the zero-based sheet row at the top of the view (for a
  /// thumbnail; the offsets are what the reader restores).
  static const row = 'row';

  /// Excel, CSV: the zero-based sheet column at the left of the view (for a
  /// thumbnail; the offsets are what the reader restores).
  static const column = 'column';

  /// Excel, CSV: the reader froze the header row itself (`true`), for a
  /// sheet whose file froze none.
  static const freezeTopRow = 'freeze_top_row';

  /// PowerPoint: the slide on screen, from 0 (an `int`).
  static const slideIndex = 'slide_index';

  /// PowerPoint: the presentation's slide count when the position was
  /// saved (an `int`).
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
