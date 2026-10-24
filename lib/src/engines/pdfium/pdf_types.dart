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

  unknown,
}

class PdfOpenException implements Exception {
  const PdfOpenException(this.error);
  final PdfOpenError error;

  @override
  String toString() => 'PdfOpenException(${error.name})';
}

/// The worker went away (e.g. the native library failed to load).
class PdfEngineException implements Exception {
  const PdfEngineException(this.message);
  final String message;

  @override
  String toString() => 'PdfEngineException: $message';
}

/// A request was cancelled before it ran.
class PdfCancelledException implements Exception {
  const PdfCancelledException();

  @override
  String toString() => 'PdfCancelledException';
}

/// How urgently a request is served: what's on screen first.
enum PdfPriority { visible, prefetch, background }

/// A page's text as PDFium reads it, with each character's box.
class PdfPageText {
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
  const PdfTextMatch({required this.page, required this.start, required this.end, required this.rects});

  /// 0-based page index.
  final int page;

  /// Offsets into the page's [PdfPageText.text].
  final int start;
  final int end;

  /// In page points from the top-left (rotation applied).
  final List<Rect> rects;
}

/// A link on a page: a web address, or a page in this document.
class PdfLink {
  const PdfLink({required this.rects, this.url, this.page});

  final List<Rect> rects;
  final String? url;

  /// 0-based target page.
  final int? page;
}
