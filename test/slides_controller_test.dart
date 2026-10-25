import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_document_viewer/universal_document_viewer.dart';
import 'package:universal_document_viewer/testing.dart';

void main() {
  final threeSlides = buildPptx([
    titleShape('Welcome'),
    titleShape('Budget') + bodyShape([('Revenue grew', 0)]),
    titleShape('Revenue outlook'),
  ]);

  // Parses inline: the isolate hop is the only difference from the default.
  SlidesController deckWith({ReadingPosition? at, void Function(ReadingPosition)? onMoved}) =>
      SlidesController(initialPosition: at, onPositionChanged: onMoved, parse: (b) async => PptxParser.parse(b));

  test('loads slides and starts on the first', () async {
    final deck = deckWith();
    await deck.load(threeSlides);
    expect(deck.isLoaded, isTrue);
    expect(deck.error, isNull);
    expect(deck.slides.map((s) => s.title), ['Welcome', 'Budget', 'Revenue outlook']);
    expect(deck.currentSlide, 0);
  });

  test('restores a saved slide, clamped to the slides that exist', () async {
    final deck = deckWith(at: {PositionKeys.slideIndex: 9});
    await deck.load(threeSlides);
    expect(deck.currentSlide, 2);
    expect(deck.pageController?.initialPage, 2);
  });

  test('reports the position when the slide changes', () async {
    ReadingPosition? reported;
    final deck = deckWith(onMoved: (p) => reported = p);
    await deck.load(threeSlides);
    deck.onSlideChanged(1);
    expect(reported, {PositionKeys.slideIndex: 1, PositionKeys.slideCount: 3});
  });

  test('typed errors for damaged files', () async {
    final deck = deckWith();
    await deck.load(Uint8List.fromList([1, 2, 3, 4]));
    expect(deck.error, DocumentLoadError.corrupted);
  });

  test('search finds slides from the one on screen and cycles', () async {
    final deck = deckWith();
    await deck.load(threeSlides);
    deck.search('REVENUE');
    expect(deck.matches, [1, 2]);
    expect(deck.currentSlide, 1);
    deck.nextMatch();
    expect(deck.currentSlide, 2);
    deck.nextMatch();
    expect(deck.currentSlide, 1);
    deck.previousMatch();
    expect(deck.currentSlide, 2);
    deck.clearSearch();
    expect(deck.matches, isEmpty);
    expect(deck.currentMatch, -1);
  });

  test('zoom steps within its limits', () async {
    final deck = deckWith();
    await deck.load(threeSlides);
    expect(deck.zoom, 1);
    deck.zoomIn();
    expect(deck.zoom, 1.25);
    for (var i = 0; i < 20; i++) {
      deck.zoomIn();
    }
    expect(deck.zoom, SlidesController.maxZoom);
    expect(deck.canZoomIn, isFalse);
    for (var i = 0; i < 20; i++) {
      deck.zoomOut();
    }
    expect(deck.zoom, SlidesController.minZoom);
    expect(deck.canZoomOut, isFalse);
  });
}
