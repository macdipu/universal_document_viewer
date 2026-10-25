import 'dart:ui';

/// Why a PDF couldn't be opened.
enum PdfOpenError {
  /// The file is missing or unreadable.
  file,

  /// Not a PDF, or damaged beyond repair.
  format,

  /// Encrypted, and no password (or a wrong one) was given.
  password,

  /// An encryption scheme PDFium doesn't support.
  security,

  /// Any other PDFium load error.
  unknown,
}

/// Thrown when PDFium can't open a document; [error] says why.
class PdfOpenException implements Exception {
  /// An open failure for [error].
  const PdfOpenException(this.error);

  /// Why the document couldn't be opened.
  final PdfOpenError error;

  @override
  String toString() => 'PdfOpenException(${error.name})';
}

/// The worker went away (e.g. the native library failed to load).
class PdfEngineException implements Exception {
  /// An engine failure described by [message].
  const PdfEngineException(this.message);

  /// What went wrong, for logs rather than for users.
  final String message;

  @override
  String toString() => 'PdfEngineException: $message';
}

/// A request was cancelled before it ran.
class PdfCancelledException implements Exception {
  /// A cancelled request.
  const PdfCancelledException();

  @override
  String toString() => 'PdfCancelledException';
}

/// How urgently a request is served: what's on screen first.
///
/// The worker runs queued requests in this order, then oldest first.
enum PdfPriority {
  /// Needed for what's on screen now (the default for renders).
  visible,

  /// Likely needed soon (the default for text, search and links).
  prefetch,

  /// Needed eventually, e.g. thumbnails (their default).
  background,
}

/// A page's text as PDFium reads it, with each character's box.
class PdfPageText {
  /// A page's [text] and its per-character [boxes].
  const PdfPageText(this.text, this.boxes);

  /// One UTF-16 unit per character PDFium reports (it adds spaces and line
  /// breaks between words and lines).
  final String text;

  /// One box per [text] unit, in page points from the top-left of the page
  /// as displayed (rotation applied). Empty boxes for generated characters.
  final List<Rect> boxes;
}

/// A search hit on one page: the boxes it covers, one per line.
class PdfTextMatch {
  /// A match of `text.substring(start, end)` on [page].
  const PdfTextMatch({required this.page, required this.start, required this.end, required this.rects});

  /// 0-based page index.
  final int page;

  /// Offset of the match's first unit in the page's [PdfPageText.text].
  final int start;

  /// Offset just past the match's last unit in [PdfPageText.text]
  /// (exclusive).
  final int end;

  /// In page points from the top-left (rotation applied).
  final List<Rect> rects;
}

/// A link on a page: a web address, or a page in this document.
class PdfLink {
  /// A link covering [rects], to [url] and/or [page].
  const PdfLink({required this.rects, this.url, this.page});

  /// The tappable areas, in page points from the top-left (rotation
  /// applied).
  final List<Rect> rects;

  /// The web address; null for a link to a page in this document.
  final String? url;

  /// 0-based target page; null for a web link.
  final int? page;
}
