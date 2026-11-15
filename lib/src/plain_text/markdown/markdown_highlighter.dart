// Internal to MarkdownView: not exported, so its members need no public docs.
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

/// Colours for syntax highlighting, taken from the theme so light, dark and
/// night mode all stay legible.
class SyntaxPalette {
  final Color keyword;
  final Color string;
  final Color number;
  final Color comment;
  final Color type;
  final Color function;
  final Color heading;
  final Color accent;
  final Color muted;

  const SyntaxPalette({
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.type,
    required this.function,
    required this.heading,
    required this.accent,
    required this.muted,
  });

  factory SyntaxPalette.of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return SyntaxPalette(
      keyword: dark ? const Color(0xFFC792EA) : const Color(0xFF7B3FB8),
      string: dark ? const Color(0xFFC3E88D) : const Color(0xFF2E7D32),
      number: dark ? const Color(0xFFF78C6C) : const Color(0xFFD84315),
      comment: scheme.onSurfaceVariant.withValues(alpha: 0.8),
      type: dark ? const Color(0xFFFFCB6B) : const Color(0xFF9A6700),
      function: dark ? const Color(0xFF82AAFF) : const Color(0xFF0B63C5),
      heading: scheme.primary,
      accent: scheme.secondary,
      muted: scheme.onSurfaceVariant,
    );
  }
}

/// A small, language-agnostic tokenizer: good enough to colour the common
/// cases (comments, strings, numbers, keywords, types, calls) in any C-like,
/// scripting or config language without shipping a grammar per language.
class CodeHighlighter {
  CodeHighlighter._();

  /// Lines longer than this are shown plain, so one minified line can't stall
  /// the UI.
  static const int maxHighlightedLine = 2000;

  static const _hashComment = {
    'py', 'python', 'sh', 'bash', 'zsh', 'shell', 'yaml', 'yml', 'toml', 'ruby',
    'rb', 'perl', 'r', 'dockerfile', //
    'makefile', 'ini', 'conf', 'powershell', 'ps1',
  };
  static const _noSlashComment = {'py', 'python', 'sh', 'bash', 'zsh', 'shell', 'yaml', 'yml', 'toml', 'ini', 'conf'};

  static final _keywords = RegExp(
    r'^(?:abstract|as|async|await|break|case|catch|class|const|continue|default|defer|do|else|enum|export|extends|'
    r'extension|false|final|finally|fn|for|from|func|function|get|go|if|impl|implements|import|in|interface|is|let|'
    r'late|match|mixin|mod|new|nil|none|null|of|on|override|package|private|protected|pub|public|return|sealed|self|'
    r'set|static|struct|super|switch|this|throw|true|try|type|typedef|typeof|undefined|use|val|var|void|when|where|'
    r'while|with|yield|def|elif|except|lambda|pass|raise|and|or|not|None|True|False|echo|fi|then|done|select|insert|'
    r'update|delete|create|table|into|values|join|group|order|by|limit)$',
  );
  static final _capitalized = RegExp(r'^[A-Z]');

  static RegExp _tokens(String? language, {required bool lineOnly}) {
    final lang = (language ?? '').toLowerCase();
    final hash = _hashComment.contains(lang);
    final slash = !_noSlashComment.contains(lang);
    final comments = [
      if (slash) r'//[^\n]*',
      if (slash) (lineOnly ? r'/\*.*?(?:\*/|$)' : r'/\*[\s\S]*?(?:\*/|$)'),
      if (hash || lang.isEmpty) r'#[^\n]*',
      if (lang == 'sql') r'--[^\n]*',
      if (lang == 'html' || lang == 'xml') r'<!--[\s\S]*?(?:-->|$)',
    ].join('|');
    return RegExp(
      '(?<comment>${comments.isEmpty ? '(?!)' : comments})'
      '|(?<string>"(?:\\\\.|[^"\\\\\\n])*"?|\'(?:\\\\.|[^\'\\\\\\n])*\'?|`(?:\\\\.|[^`\\\\])*`?)'
      r'|(?<number>\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*\.?\d*(?:[eE][+-]?\d+)?)\b)'
      r'|(?<word>[A-Za-z_$][A-Za-z0-9_$]*)',
      multiLine: true,
    );
  }

  static final _cache = <String, RegExp>{};

  /// Colours [code] (one or many lines). [language] is a fence info string
  /// such as `dart` or `json`; unknown or missing languages use the generic
  /// rules.
  static List<TextSpan> highlight(String code, String? language, SyntaxPalette palette, {bool lineOnly = false}) {
    if (code.isEmpty) return const [];
    final lang = language?.split(RegExp(r'\s+')).first.toLowerCase();
    final regex = _cache.putIfAbsent('${lang ?? ''}|$lineOnly', () => _tokens(lang, lineOnly: lineOnly));
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in regex.allMatches(code)) {
      if (m.start > last) spans.add(TextSpan(text: code.substring(last, m.start)));
      final text = m.group(0)!;
      final TextStyle? style;
      if (m.namedGroup('comment') != null) {
        style = TextStyle(color: palette.comment, fontStyle: FontStyle.italic);
      } else if (m.namedGroup('string') != null) {
        style = TextStyle(color: palette.string);
      } else if (m.namedGroup('number') != null) {
        style = TextStyle(color: palette.number);
      } else if (_keywords.hasMatch(text)) {
        style = TextStyle(color: palette.keyword, fontWeight: FontWeight.w600);
      } else if (_capitalized.hasMatch(text)) {
        style = TextStyle(color: palette.type);
      } else if (m.end < code.length && code[m.end] == '(') {
        style = TextStyle(color: palette.function);
      } else {
        style = null;
      }
      spans.add(TextSpan(text: text, style: style));
      last = m.end;
    }
    if (last < code.length) spans.add(TextSpan(text: code.substring(last)));
    return spans;
  }
}

/// Colours Markdown source line by line. Fenced code blocks are tracked across
/// lines so their contents get code colouring, not Markdown colouring.
class MarkdownSourceHighlighter {
  final List<String> lines;
  late final List<String?> _fenceLanguage = _scanFences();
  late final List<bool> _inFence = _scanInFence();

  MarkdownSourceHighlighter(this.lines);

  static final _fence = RegExp(r'^ {0,3}(```|~~~)\s*([\w+#.-]*)');
  static final _heading = RegExp(r'^( {0,3}#{1,6})(\s.*|$)');
  static final _quote = RegExp(r'^(\s*>+)(.*)$');
  static final _list = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)(.*)$');
  static final _rule = RegExp(r'^ {0,3}([-*_])(\s*\1){2,}\s*$');
  static final _inline = RegExp(
    r'(?<code>`[^`\n]+`)|(?<link>!?\[[^\]\n]*\]\([^)\n]*\))|(?<bold>\*\*[^*\n]+\*\*|__[^_\n]+__)'
    r'|(?<em>\*[^*\n]+\*|_[^_\n]+_)|(?<url><https?://[^>\s]+>)',
  );

  // Per line: the fence language on an opening fence line, '' on a closing
  // or unlabeled one, null for any other line.
  List<String?> _scanFences() {
    final out = List<String?>.filled(lines.length, null);
    var open = false;
    for (var i = 0; i < lines.length; i++) {
      final m = _fence.firstMatch(lines[i]);
      if (m != null) {
        out[i] = open ? '' : m.group(2) ?? '';
        open = !open;
      }
    }
    return out;
  }

  List<bool> _scanInFence() {
    final out = List<bool>.filled(lines.length, false);
    var open = false;
    for (var i = 0; i < lines.length; i++) {
      if (_fenceLanguage[i] != null) {
        open = !open;
      } else {
        out[i] = open;
      }
    }
    return out;
  }

  String? _languageAt(int line) {
    for (var i = line - 1; i >= 0; i--) {
      if (_fenceLanguage[i] != null) return _fenceLanguage[i];
    }
    return null;
  }

  List<TextSpan> spansFor(int index, SyntaxPalette p) {
    final line = lines[index];
    if (line.isEmpty) return const [];
    if (line.length > CodeHighlighter.maxHighlightedLine) return [TextSpan(text: line)];
    if (_fenceLanguage[index] != null) return [TextSpan(text: line, style: TextStyle(color: p.muted))];
    if (_inFence[index]) {
      return CodeHighlighter.highlight(line, _languageAt(index), p, lineOnly: true);
    }
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      return [
        TextSpan(text: heading.group(1), style: TextStyle(color: p.accent, fontWeight: FontWeight.w700)),
        TextSpan(text: heading.group(2), style: TextStyle(color: p.heading, fontWeight: FontWeight.w700)),
      ];
    }
    if (_rule.hasMatch(line)) return [TextSpan(text: line, style: TextStyle(color: p.muted))];
    final quote = _quote.firstMatch(line);
    if (quote != null) {
      return [
        TextSpan(text: quote.group(1), style: TextStyle(color: p.accent)),
        TextSpan(text: quote.group(2), style: TextStyle(color: p.muted, fontStyle: FontStyle.italic)),
      ];
    }
    final list = _list.firstMatch(line);
    if (list != null) {
      return [TextSpan(text: list.group(1), style: TextStyle(color: p.accent)), ..._inlineSpans(list.group(2)!, p)];
    }
    return _inlineSpans(line, p);
  }

  List<TextSpan> _inlineSpans(String text, SyntaxPalette p) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final TextStyle style;
      if (m.namedGroup('code') != null) {
        style = TextStyle(color: p.string);
      } else if (m.namedGroup('bold') != null) {
        style = const TextStyle(fontWeight: FontWeight.w700);
      } else if (m.namedGroup('em') != null) {
        style = const TextStyle(fontStyle: FontStyle.italic);
      } else {
        style = TextStyle(color: p.function);
      }
      spans.add(TextSpan(text: m.group(0), style: style));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }
}
