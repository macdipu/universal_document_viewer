import 'package:flutter/widgets.dart';

import 'document_viewer_theme.dart';

/// [text] split into spans with every case-insensitive occurrence of [query]
/// highlighted by [theme]; the one starting at [currentStart] stands out as
/// the current match. Shared by the text views' search highlighting.
List<InlineSpan> matchSpans(String text, String query, DocumentViewerTheme theme, {int? currentStart}) {
  final lower = text.toLowerCase();
  final needle = query.toLowerCase();
  final spans = <InlineSpan>[];
  var start = 0;
  while (true) {
    final index = needle.isEmpty ? -1 : lower.indexOf(needle, start);
    if (index == -1) {
      spans.add(TextSpan(text: text.substring(start)));
      return spans;
    }
    if (index > start) spans.add(TextSpan(text: text.substring(start, index)));
    spans.add(
      TextSpan(
        text: text.substring(index, index + needle.length),
        style: theme.matchStyle(current: index == currentStart),
      ),
    );
    start = index + needle.length;
  }
}
