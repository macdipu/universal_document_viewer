import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Paints [page] - a widget laid out at [size] logical pixels - into an
/// image [width] pixels wide, without putting it on screen.
///
/// The widget gets its own render and element trees (a [RenderView] over a
/// [RenderRepaintBoundary], driven by a private [PipelineOwner] and
/// [BuildOwner]), under [theme] on white paper with left-to-right text.
/// Pictures in it ([Image] widgets) are waited for, up to [imageTimeout],
/// so they're in the picture rather than blank. Overflow is clipped to
/// [size]. Throws if any widget fails to build. Runs on the UI isolate: it
/// needs the widgets binding.
Future<ui.Image> renderOffscreen(
  Widget page, {
  required Size size,
  required int width,
  ThemeData? theme,
  Duration imageTimeout = const Duration(seconds: 3),
}) async {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView ??
      WidgetsBinding.instance.platformDispatcher.views.first;
  final boundary = RenderRepaintBoundary();
  final positioned = RenderPositionedBox(alignment: Alignment.topLeft, child: boundary);
  final renderView = RenderView(
    view: view,
    configuration: ViewConfiguration(logicalConstraints: BoxConstraints.tight(size), physicalConstraints: BoxConstraints.tight(size)),
    child: positioned,
  );
  final pipelineOwner = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final focusManager = FocusManager();
  final buildOwner = BuildOwner(focusManager: focusManager);

  // What MaterialApp would provide (selectable text wants localizations and
  // an overlay); the default English localizations load synchronously, so
  // the first frame already has them.
  final tree = MediaQuery(
    data: MediaQueryData(size: size),
    child: Localizations(
      locale: const Locale('en', 'US'),
      delegates: const [DefaultMaterialLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: theme ?? ThemeData(colorScheme: const ColorScheme.light(surface: Colors.white)),
          child: ScrollConfiguration(
            behavior: const _StillScrollBehavior(),
            child: Overlay.wrap(
              child: Material(
                color: Colors.white,
                child: SizedBox.fromSize(size: size, child: ClipRect(child: page)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final root = RenderObjectToWidgetAdapter<RenderBox>(container: boundary, child: tree).attachToRenderTree(buildOwner);

  void drawFrame() {
    buildOwner.buildScope(root);
    buildOwner.finalizeTree();
    pipelineOwner.flushLayout();
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();
  }

  try {
    drawFrame();
    if (await _imagesLoaded(root, imageTimeout)) drawFrame();
    // A widget that failed to build shows as an error box: no thumbnail
    // rather than a picture of that.
    if (_containsErrorWidget(root)) throw StateError('A widget failed to build offscreen');
    // `toImage` rounds the scaled size up; scaling by a hair under
    // width / size.width keeps the result exactly [width] pixels wide.
    return await boundary.toImage(pixelRatio: (width - 1e-6) / size.width);
  } finally {
    // Unmount the widgets, so their states (image listeners, gesture
    // recognizers) are disposed.
    RenderObjectToWidgetAdapter<RenderBox>(container: boundary).attachToRenderTree(buildOwner, root);
    buildOwner.buildScope(root);
    buildOwner.finalizeTree();
    focusManager.dispose();
    pipelineOwner.rootNode = null;
    pipelineOwner.dispose();
    for (final renderObject in [boundary, positioned, renderView]) {
      renderObject.dispose();
    }
  }
}

/// Waits until every [Image] under [root] has its first frame (or failed),
/// at most [timeout]. True when there were images, so the caller redraws.
Future<bool> _imagesLoaded(Element root, Duration timeout) async {
  final pending = <(ImageStream, ImageStreamListener, Completer<void>)>[];
  void visit(Element element) {
    if (element.widget case final Image image) {
      final done = Completer<void>();
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      final listener = ImageStreamListener((_, _) => finish(), onError: (_, _) => finish());
      final stream = image.image.resolve(createLocalImageConfiguration(element))..addListener(listener);
      pending.add((stream, listener, done));
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  if (pending.isEmpty) return false;
  try {
    await Future.wait([for (final (_, _, done) in pending) done.future]).timeout(timeout);
  } on TimeoutException {
    // Draw what has arrived; a missing picture stays blank.
  } finally {
    for (final (stream, listener, _) in pending) {
      stream.removeListener(listener);
    }
  }
  return true;
}

bool _containsErrorWidget(Element root) {
  var found = false;
  void visit(Element element) {
    if (element.widget is ErrorWidget) found = true;
    if (!found) element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found;
}

/// For scroll views in an offscreen page, which never scroll: no scrollbars
/// or glow, and pictures in them load at once. (Asking whether to defer a
/// picture's loading looks up the [View], which an offscreen tree has none
/// of - the picture would fail.)
class _StillScrollBehavior extends ScrollBehavior {
  const _StillScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const _NoDeferredLoadingPhysics();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

class _NoDeferredLoadingPhysics extends ClampingScrollPhysics {
  const _NoDeferredLoadingPhysics({super.parent});

  @override
  _NoDeferredLoadingPhysics applyTo(ScrollPhysics? ancestor) => _NoDeferredLoadingPhysics(parent: buildParent(ancestor));

  @override
  bool recommendDeferredLoading(double velocity, ScrollMetrics metrics, BuildContext context) => false;
}
