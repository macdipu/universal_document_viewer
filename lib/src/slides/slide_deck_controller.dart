import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../common/reader_contract.dart';
import '../common/zip_safety_guard.dart';
import 'pptx_parser.dart';

/// State for [SlideDeckView]: the slides of a `.pptx`, which one is on
/// screen, and search across them.
///
/// Bytes pass [ZipSafetyGuard] before anything decompresses them, and
/// parsing runs off the UI isolate. The slide on screen is reported through
/// [onPositionChanged] as `{slide_index, slide_count}`; saving it (and any
/// debouncing) is the app's business.
class SlideDeckController extends ChangeNotifier {
  SlideDeckController({
    ReadingPosition? initialPosition,
    this.onPositionChanged,
    Future<PptxPresentation> Function(Uint8List bytes)? parse,
  }) : _initialSlide = switch (initialPosition?[PositionKeys.slideIndex]) {
         final int index when index > 0 => index,
         _ => 0,
       },
       _parse = parse ?? ((bytes) => Isolate.run(() => PptxParser.parse(bytes)));

  final int _initialSlide;
  final Future<PptxPresentation> Function(Uint8List bytes) _parse;

  /// Called whenever the slide on screen settles on a new one.
  final ValueChanged<ReadingPosition>? onPositionChanged;

  bool _disposed = false;

  bool _loaded = false;

  /// True once [load] finished, successfully or not.
  bool get isLoaded => _loaded;

  DocumentLoadError? _error;
  DocumentLoadError? get error => _error;

  List<PptxSlide> _slides = const [];
  List<PptxSlide> get slides => _slides;

  int _current = 0;

  /// Zero-based slide on screen.
  int get currentSlide => _current;

  PageController? _pageController;

  /// Created by [load], starting on the restored slide.
  PageController? get pageController => _pageController;

  ReadingPosition get position => {PositionKeys.slideIndex: _current, PositionKeys.slideCount: _slides.length};

  /// Parses [bytes]. A restored slide past the end (the file may have lost
  /// slides since) is clamped to the last one.
  Future<void> load(Uint8List bytes) async {
    try {
      switch (ZipSafetyGuard.check(bytes)) {
        case ZipSafetyResult.safe:
          final presentation = await _parse(bytes);
          if (_disposed) return;
          _slides = presentation.slides;
        case ZipSafetyResult.tooLarge:
          _error = DocumentLoadError.tooLarge;
        case ZipSafetyResult.corrupted:
          _error = DocumentLoadError.corrupted;
      }
    } catch (_) {
      _error = DocumentLoadError.corrupted;
    }
    if (_disposed) return;
    if (_error == null) {
      _current = _slides.isEmpty ? 0 : _initialSlide.clamp(0, _slides.length - 1);
      _pageController = PageController(initialPage: _current);
    }
    _loaded = true;
    notifyListeners();
  }

  /// The page view reports every settled page here.
  void onSlideChanged(int index) {
    _current = index;
    notifyListeners();
    onPositionChanged?.call(position);
  }

  bool get canGoPrevious => _current > 0;
  bool get canGoNext => _current < _slides.length - 1;

  void previousSlide() {
    if (canGoPrevious) goToSlide(_current - 1);
  }

  void nextSlide() {
    if (canGoNext) goToSlide(_current + 1);
  }

  void goToSlide(int index) {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) {
      onSlideChanged(index);
      return;
    }
    controller.animateToPage(index, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  String _query = '';
  String get searchQuery => _query;

  List<int> _matches = const [];

  /// Indices of slides whose text contains [searchQuery].
  List<int> get matches => _matches;

  int _currentMatch = -1;

  /// Position within [matches], or -1 before the first jump.
  int get currentMatch => _currentMatch;

  /// Finds the slides containing [query] (any case) and jumps to the first
  /// one at or after the slide on screen.
  void search(String query) {
    _query = query;
    final needle = query.trim().toLowerCase();
    _matches = needle.isEmpty
        ? const []
        : [
            for (var i = 0; i < _slides.length; i++)
              if (_slides[i].text.toLowerCase().contains(needle)) i,
          ];
    if (_matches.isEmpty) {
      _currentMatch = -1;
      notifyListeners();
      return;
    }
    final ahead = _matches.indexWhere((i) => i >= _current);
    _goToMatch(ahead == -1 ? 0 : ahead);
  }

  void clearSearch() => search('');

  void nextMatch() {
    if (_matches.isNotEmpty) _goToMatch((_currentMatch + 1) % _matches.length);
  }

  void previousMatch() {
    if (_matches.isNotEmpty) _goToMatch((_currentMatch - 1 + _matches.length) % _matches.length);
  }

  void _goToMatch(int index) {
    _currentMatch = index;
    notifyListeners();
    goToSlide(_matches[index]);
  }

  @override
  void dispose() {
    _disposed = true;
    _pageController?.dispose();
    super.dispose();
  }
}
