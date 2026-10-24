/// A document type universal_document_viewer can read, and how files map to it.
enum DocumentFormat {
  pdf,
  word,
  excel,
  powerpoint,
  text,
  csv;

  /// Legacy binary `.doc`/`.xls`/`.ppt` are deliberately absent: the Word,
  /// Excel and PowerPoint engines read OOXML (ZIP) only, so those files
  /// could only ever fail as "damaged".
  static const Map<String, DocumentFormat> _byExtension = {
    'pdf': DocumentFormat.pdf,
    'docx': DocumentFormat.word,
    'xlsx': DocumentFormat.excel,
    'pptx': DocumentFormat.powerpoint,
    'txt': DocumentFormat.text,
    'md': DocumentFormat.text,
    'markdown': DocumentFormat.text,
    'csv': DocumentFormat.csv,
  };

  static const Map<String, String> _extensionByMimeType = {
    'application/pdf': 'pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
    'text/plain': 'txt',
    'text/markdown': 'md',
    'text/x-markdown': 'md',
    'text/csv': 'csv',
    'text/comma-separated-values': 'csv',
  };

  /// Every extension the kit reads, without the dot.
  static List<String> get supportedExtensions => _byExtension.keys.toList();

  /// [extension] with or without its dot, any case; null if unsupported.
  static DocumentFormat? fromExtension(String extension) {
    final normalized = extension.startsWith('.') ? extension.substring(1) : extension;
    return _byExtension[normalized.toLowerCase()];
  }

  /// From a file name or path's extension; null if unsupported.
  static DocumentFormat? fromPath(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return fromExtension(name.substring(dot + 1));
  }

  /// The extension for a MIME type another app reported (e.g. a shared
  /// file with no extension of its own); null if unsupported.
  static String? extensionForMimeType(String mimeType) => _extensionByMimeType[mimeType.toLowerCase()];
}
