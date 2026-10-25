import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../common/document_controller.dart';
import '../common/reader_contract.dart';
import '../common/zip_safety_guard.dart';
import '../engines/slides/pptx_parser.dart';

/// One occurrence of a search in a presentation: the [occurrence]th match
/// (from 0) on slide [slide] (from 0), counting in the order [SlidesView]
/// draws the slide's text - title, then paragraphs and table cells.
@immutable
class SlideMatch {
  /// The [occurrence]th match on slide [slide].
  const SlideMatch(this.slide, this.occurrence);

  /// The slide, from 0.
  final int slide;

  /// Which match on that slide, from 0.
  final int occurrence;

  @override
  bool operator ==(Object other) => other is SlideMatch && other.slide == slide && other.occurrence == occurrence;

  @override
  int get hashCode => Object.hash(slide, occurrence);
}

/// Loads a PowerPoint (`.pptx`) presentation for [SlidesView]: its
/// slides, the one on screen, zoom and search.
///
/// Bytes pass [ZipSafetyGuard] before anything decompresses them, and
/// parsing runs off the UI isolate. The [position] is
/// `{slide_index, slide_count}`.
class SlidesController extends DocumentController {
  /// Opens on the slide saved in [initialPosition], if any.
  ///
  /// [parse] replaces the background-isolate parser, for tests.
  SlidesController({
    ReadingPosition? initialPosition,
    super.onPositionChanged,
    Future<PptxPresentation> Function(Uint8List bytes)? parse,
  }) : _initialSlide = switch (initialPosition?[PositionKeys.slideIndex]) {
         final int index when index > 0 => index,
         _ => 0,
       },
       _parse = parse ?? ((bytes) => Isolate.run(() => PptxParser.parse(bytes)));

  final int _initialSlide;
  final Future<PptxPresentation> Function(Uint8List bytes) _parse;

  List<PptxSlide> _slides = const [];

  /// The presentation's slides; empty until loaded.
  List<PptxSlide> get slides => _slides;

  int _current = 0;

  /// The slide on screen, from 0.
  int get currentSlide => _current;

  PageController? _pageController;

  /// Drives [SlidesView]'s pages; created by [loadBytes], starting on the
  /// restored slide.
  @internal
  PageController? get pageController => _pageController;

  @override
  ReadingPosition get position => {PositionKeys.slideIndex: _current, PositionKeys.slideCount: _slides.length};

  /// Parses [bytes]. A restored slide past the end (the file may have lost
  /// slides since) is clamped to the last one.
  @override
  Future<void> loadBytes(Uint8List bytes) async {
    markLoading();
    DocumentLoadError? error;
    try {
      switch (ZipSafetyGuard.check(bytes)) {
        case ZipSafetyResult.safe:
          final presentation = await _parse(bytes);
          if (isDisposed) return;
          _slides = presentation.slides;
        case ZipSafetyResult.tooLarge:
          error = DocumentLoadError.tooLarge;
        case ZipSafetyResult.corrupted:
          error = DocumentLoadError.corrupted;
      }
    } catch (_) {
      error = DocumentLoadError.corrupted;
    }
    if (isDisposed) return;
    if (error != null) {
      markFailed(error);
      return;
    }
    _current = _slides.isEmpty ? 0 : _initialSlide.clamp(0, _slides.length - 1);
    _pageController?.dispose();
    _pageController = PageController(initialPage: _current);
    _updateLocation();
    markReady();
  }

  void _updateLocation() =>
      updateLocation(DocumentLocation(current: _current + 1, count: _slides.length, unit: DocumentUnit.slide));

  /// [SlidesView] reports each slide it settles on here.
  @internal
  void onSlideChanged(int index) {
    if (index == _current) return;
    _current = index;
    _updateLocation();
    notifyListeners();
    reportPosition();
  }

  // ---- Navigation

  /// Whether there's a slide before the current one.
  bool get canGoPrevious => _current > 0;

  /// Whether there's a slide after the current one.
  bool get canGoNext => _current < _slides.length - 1;

  /// Shows the previous slide.
  void previousSlide() {
    if (canGoPrevious) goToSlide(_current - 1);
  }

  /// Shows the next slide.
  void nextSlide() {
    if (canGoNext) goToSlide(_current + 1);
  }

  /// Shows slide [index] (from 0).
  void goToSlide(int index) {
    if (_slides.isEmpty) return deferGoTo(index + 1);
    index = index.clamp(0, _slides.length - 1);
    final controller = _pageController;
    if (controller == null || !controller.hasClients) {
      onSlideChanged(index);
      return;
    }
    controller.animateToPage(index, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// Shows slide [number] (from 1).
  @override
  void goTo(int number) => goToSlide(number - 1);

  // ---- Zoom

  double _zoom = 1;

  /// How large the slides' text is drawn; [SlidesView] reflows it.
  @override
  double get zoom => _zoom;

  @override
  double get minZoom => 0.75;

  @override
  double get maxZoom => 2.5;

  @override
  void setZoom(double zoom) {
    zoom = zoom.clamp(minZoom, maxZoom);
    if (zoom == _zoom) return;
    _zoom = zoom;
    notifyListeners();
  }

  // ---- Search

  String _query = '';

  /// The text being searched for (trimmed); empty when there's no search.
  String get searchQuery => _query;

  List<SlideMatch> _matches = const [];

  /// Every occurrence of [searchQuery], slide by slide.
  List<SlideMatch> get matches => _matches;

  int _currentMatch = -1;

  /// Which of [matches] is current, or -1 when there are none.
  int get currentMatch => _currentMatch;

  /// The current match, if any.
  SlideMatch? get currentSlideMatch => _currentMatch < 0 ? null : _matches[_currentMatch];

  /// Finds every occurrence of [query] (ignoring case) and shows the first
  /// one on or after the slide on screen.
  @override
  void search(String query) {
    _query = query.trim();
    final needle = _query.toLowerCase();
    _matches = needle.isEmpty
        ? const []
        : [
            for (var i = 0; i < _slides.length; i++)
              for (var n = 0, count = _occurrences(_slides[i], needle); n < count; n++) SlideMatch(i, n),
          ];
    if (_matches.isEmpty) {
      _currentMatch = -1;
      _updateSearch();
      notifyListeners();
      return;
    }
    final ahead = _matches.indexWhere((m) => m.slide >= _current);
    _goToMatch(ahead == -1 ? 0 : ahead);
  }

  /// How many times [needle] occurs in [slide]'s text, segment by segment
  /// (never across a title and a paragraph, or two cells).
  static int _occurrences(PptxSlide slide, String needle) {
    var count = 0;
    void add(String text) => count += countOccurrences(text, needle);
    if (slide.title case final title?) add(title);
    for (final block in slide.blocks) {
      switch (block) {
        case PptxParagraph(:final text):
          add(text);
        case PptxTable(:final rows):
          for (final row in rows) {
            row.forEach(add);
          }
        case PptxImage():
          break;
      }
    }
    return count;
  }

  /// How many times [needle] (already lower-case) occurs in [text],
  /// ignoring case and not overlapping.
  @internal
  static int countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;
    final haystack = text.toLowerCase();
    var count = 0;
    for (var i = haystack.indexOf(needle); i != -1; i = haystack.indexOf(needle, i + needle.length)) {
      count++;
    }
    return count;
  }

  @override
  void nextMatch() {
    if (_matches.isNotEmpty) _goToMatch((_currentMatch + 1) % _matches.length);
  }

  @override
  void previousMatch() {
    if (_matches.isNotEmpty) _goToMatch((_currentMatch - 1 + _matches.length) % _matches.length);
  }

  void _goToMatch(int index) {
    _currentMatch = index;
    _updateSearch();
    notifyListeners();
    goToSlide(_matches[index].slide);
  }

  void _updateSearch() =>
      updateSearch(DocumentSearchState(query: _query, matchCount: _matches.length, currentMatch: _currentMatch));

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }
}
