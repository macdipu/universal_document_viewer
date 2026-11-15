/// How [MarkdownView] shows a document.
enum MarkdownViewMode {
  /// The rendered document.
  preview,

  /// The highlighted source, with line numbers.
  code,

  /// Source and preview together, scrolling as one.
  split,
}

/// Figures about a Markdown source, computed from the text alone (so every
/// value is reliable). Fenced code is skipped when counting headings, links
/// and images.
class MarkdownStats {
  /// Counts for a source: use [MarkdownStats.of].
  const MarkdownStats({
    required this.words,
    required this.characters,
    required this.lines,
    required this.headings,
    required this.links,
    required this.images,
    required this.readingMinutes,
  });

  /// Counts the source given as [lines].
  factory MarkdownStats.of(List<String> lines) {
    var words = 0;
    var characters = 0;
    var headings = 0;
    var links = 0;
    var images = 0;
    var inFence = false;
    for (final line in lines) {
      characters += line.runes.length;
      words += _word.allMatches(line).length;
      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      if (_heading.hasMatch(line)) headings++;
      images += _image.allMatches(line).length;
      links += _link.allMatches(line).length;
    }
    // Line breaks count as characters, as editors report them.
    if (lines.length > 1) characters += lines.length - 1;
    return MarkdownStats(
      words: words,
      characters: characters,
      lines: lines.length,
      headings: headings,
      links: links,
      images: images,
      readingMinutes: words == 0 ? 0 : (words / _wordsPerMinute).ceil(),
    );
  }

  /// Whitespace-separated words, code included.
  final int words;

  /// Unicode characters (code points), line breaks included.
  final int characters;

  /// Lines in the source.
  final int lines;

  /// ATX headings (`#` to `######`) outside fenced code.
  final int headings;

  /// Inline links and `<https://…>` autolinks outside fenced code.
  final int links;

  /// Inline images outside fenced code.
  final int images;

  /// Whole minutes at 220 words per minute; 0 for an empty document.
  final int readingMinutes;

  static final _heading = RegExp(r'^ {0,3}#{1,6}(\s|$)');
  static final _fence = RegExp(r'^ {0,3}(```|~~~)');
  static final _image = RegExp(r'!\[[^\]]*\]\([^)\s]+[^)]*\)');
  static final _link = RegExp(r'(?<!!)\[[^\]]*\]\([^)\s]+[^)]*\)|<https?://[^>\s]+>');
  static final _word = RegExp(r'\S+');

  static const int _wordsPerMinute = 220;
}
