import 'dart:ui';

import 'package:flutter/foundation.dart';

/// An image to read text from.
@immutable
class OcrInput {
  /// A PNG image of [width] x [height] pixels. [languageHints] are language
  /// codes ("en", "bn") the recognizer may use to pick its model; empty
  /// leaves the choice to it.
  const OcrInput({required this.png, required this.width, required this.height, this.languageHints = const []});

  /// The image, PNG encoded.
  final Uint8List png;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Languages the text is likely in; empty when unknown.
  final List<String> languageHints;
}

/// A line of recognised text.
@immutable
class OcrLine {
  /// A [text] line occupying [rect] (image pixels from the top-left).
  /// [confidence] is 0 to 1, or null when the recognizer doesn't say.
  const OcrLine({required this.text, required this.rect, this.confidence});

  /// What the line says.
  final String text;

  /// Where the line is on the image, in pixels from the top-left.
  final Rect rect;

  /// How sure the recognizer is, from 0 to 1; null when unknown.
  final double? confidence;
}

/// What a [TextRecognizer] read from an image.
@immutable
class OcrResult {
  /// Recognised [lines] in reading order. [detectedLanguage] is a language
  /// code when the recognizer worked it out.
  const OcrResult({required this.lines, this.detectedLanguage});

  /// No text found.
  static const empty = OcrResult(lines: []);

  /// The lines, top to bottom.
  final List<OcrLine> lines;

  /// The language the recognizer decided on ("en"); null when it doesn't
  /// say.
  final String? detectedLanguage;

  /// All the text, a line per line.
  String get text => lines.map((l) => l.text).join('\n');

  /// Whether nothing was found.
  bool get isEmpty => lines.every((l) => l.text.trim().isEmpty);
}

/// Reads text from images (OCR).
///
/// The package has no recognizer of its own, so it adds no heavy
/// dependency: an app brings one (a wrapper around the platform's text
/// recognition) and hands it to the viewer, which uses it for pages that
/// have no text layer. Everything stays on the device unless the
/// implementation sends it elsewhere.
abstract class TextRecognizer {
  /// Base constructor for implementations.
  const TextRecognizer();

  /// Whether this recognizer can run here (a platform without one, or a
  /// missing language pack, says false). The viewer offers OCR only when
  /// this is true.
  bool get isAvailable;

  /// Whether the recognizer works out the language itself. When false, an
  /// app may pass [OcrInput.languageHints] it chose.
  bool get supportsAutoDetect => false;

  /// Reads the text on [input]. Throws on failure; the viewer reports the
  /// page as failed and goes on.
  Future<OcrResult> recognize(OcrInput input);
}
