import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/reader_contract.dart';
import '../common/text_lines_controller.dart';
import '../common/text_decoding.dart';

/// Loads a plain-text document for [PlainTextView]: its lines, line wrap,
/// zoom, search and the scroll position.
///
/// Text is decoded as UTF-8, or after a UTF-16 byte order mark, falling
/// back to Latin-1. The [position] is `{scroll_offset, line}` (`line`, the
/// top visible line, once the view has measured its lines).
class PlainTextController extends TextLinesController {
  /// Reopens at the scroll offset saved in [initialPosition], if any.
  PlainTextController({super.initialPosition, super.onPositionChanged, bool wrap = true}) : _wrap = wrap;

  /// Above this size a file is refused rather than read into memory in one
  /// pass.
  static const int maxBytes = TextLinesController.maxBytes;

  /// Whether [bytes] look like a binary file rather than text; see
  /// [looksLikeBinary], which this forwards to.
  static bool looksBinary(Uint8List bytes) => looksLikeBinary(bytes);

  /// Fallback line height for jumps before the view has measured real
  /// lines.
  static const double _approxLineHeight = 20;

  /// The view's vertical scrolling.
  @internal
  final scrollController = ScrollController();

  /// Scroll offset of a line's top, measured by the view against the real
  /// font, width and wrap. Null until the view lays out.
  @internal
  double Function(int lineIndex)? lineOffsetResolver;

  /// The line at a scroll offset: the inverse of [lineOffsetResolver], set
  /// by the view alongside it.
  @internal
  int Function(double offset)? lineAtOffsetResolver;

  // ---- Where the reader is

  int _topLine = 0;
  bool _topLineKnown = false;
  double? _offset;

  @override
  int get topLine => _topLine;

  @override
  void updateLineLocation(int topLine) {
    _topLine = topLine;
    super.updateLineLocation(topLine);
  }

  /// `line` is there once the view has measured its lines.
  @override
  ReadingPosition get position => {
    PositionKeys.scrollOffset: _offset ?? initialScrollOffset,
    if (_topLineKnown) PositionKeys.line: _topLine,
  };

  /// [PlainTextView] reports every scroll here.
  @internal
  void onScrolled(double offset) {
    _offset = offset;
    if (lineAtOffsetResolver?.call(offset) case final line?) {
      _topLineKnown = true;
      updateLineLocation(line);
    }
    reportPosition();
  }

  /// Scrolls line [number] (from 1) to the top.
  @override
  void goTo(int number) {
    if (lines.isEmpty || !scrollController.hasClients) return deferGoTo(number);
    _jumpToLine(number.clamp(1, lines.length) - 1, animate: false);
  }

  @override
  void revealLine(int lineIndex) => _jumpToLine(lineIndex);

  void _jumpToLine(int lineIndex, {bool animate = true}) {
    if (!scrollController.hasClients) return;
    final offset = lineOffsetResolver?.call(lineIndex) ?? lineIndex * _approxLineHeight;
    final target = offset.clamp(0.0, scrollController.position.maxScrollExtent);
    if (animate) {
      scrollController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
    } else {
      scrollController.jumpTo(target);
    }
  }

  // ---- Wrap

  bool _wrap;

  /// Whether long lines wrap; when false each line scrolls sideways.
  bool get wrap => _wrap;

  set wrap(bool value) {
    if (value == _wrap) return;
    _wrap = value;
    notifyListeners();
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}
