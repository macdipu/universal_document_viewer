import 'package:flutter/material.dart';

/// Colours the package's views use for search matches, as a
/// [ThemeExtension] on the app's theme.
///
/// Without one, matches use the theme's secondary container colour and the
/// current match its tertiary container colour. To change them:
///
/// ```dart
/// MaterialApp(
///   theme: ThemeData(
///     extensions: const [
///       DocumentViewerTheme(matchBackground: Color(0xFFFFF59D), currentMatchBackground: Color(0xFFFFB74D)),
///     ],
///   ),
/// )
/// ```
@immutable
class DocumentViewerTheme extends ThemeExtension<DocumentViewerTheme> {
  /// Colours for search matches; any left null come from the theme.
  const DocumentViewerTheme({
    this.matchBackground,
    this.matchForeground,
    this.currentMatchBackground,
    this.currentMatchForeground,
  });

  /// Behind a search match.
  final Color? matchBackground;

  /// A search match's text.
  final Color? matchForeground;

  /// Behind the current search match (and a spreadsheet's go-to cell).
  final Color? currentMatchBackground;

  /// The current search match's text.
  final Color? currentMatchForeground;

  /// The theme's [DocumentViewerTheme], with every colour filled in from
  /// its colour scheme where the extension (or the colour) is missing.
  static DocumentViewerTheme of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final custom = theme.extension<DocumentViewerTheme>();
    return DocumentViewerTheme(
      matchBackground: custom?.matchBackground ?? scheme.secondaryContainer,
      matchForeground: custom?.matchForeground ?? scheme.onSecondaryContainer,
      currentMatchBackground: custom?.currentMatchBackground ?? scheme.tertiaryContainer,
      currentMatchForeground: custom?.currentMatchForeground ?? scheme.onTertiaryContainer,
    );
  }

  /// The text style for a match, current or not.
  TextStyle matchStyle({required bool current}) => TextStyle(
    backgroundColor: current ? currentMatchBackground : matchBackground,
    color: current ? currentMatchForeground : matchForeground,
  );

  @override
  DocumentViewerTheme copyWith({
    Color? matchBackground,
    Color? matchForeground,
    Color? currentMatchBackground,
    Color? currentMatchForeground,
  }) => DocumentViewerTheme(
    matchBackground: matchBackground ?? this.matchBackground,
    matchForeground: matchForeground ?? this.matchForeground,
    currentMatchBackground: currentMatchBackground ?? this.currentMatchBackground,
    currentMatchForeground: currentMatchForeground ?? this.currentMatchForeground,
  );

  @override
  DocumentViewerTheme lerp(DocumentViewerTheme? other, double t) {
    if (other == null) return this;
    return DocumentViewerTheme(
      matchBackground: Color.lerp(matchBackground, other.matchBackground, t),
      matchForeground: Color.lerp(matchForeground, other.matchForeground, t),
      currentMatchBackground: Color.lerp(currentMatchBackground, other.currentMatchBackground, t),
      currentMatchForeground: Color.lerp(currentMatchForeground, other.currentMatchForeground, t),
    );
  }
}
