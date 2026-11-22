import 'package:flutter/material.dart';

import 'document_controller.dart';

/// A [SelectionArea] that also tells a [DocumentController] what is
/// selected, and lets the controller clear the selection or select all.
///
/// With no [controller] it is a plain [SelectionArea]. Several of these can
/// share one controller (a slide per page, say): the one built last answers
/// the controller's calls, and a disposed one lets go only of what it
/// registered.
class DocumentSelectionArea extends StatefulWidget {
  /// Makes [child]'s text selectable and reports it to [controller].
  const DocumentSelectionArea({super.key, this.controller, required this.child});

  /// The controller to keep informed; null for no reporting.
  final DocumentController? controller;

  /// The content to make selectable.
  final Widget child;

  @override
  State<DocumentSelectionArea> createState() => _DocumentSelectionAreaState();
}

class _DocumentSelectionAreaState extends State<DocumentSelectionArea> {
  final _area = GlobalKey<SelectionAreaState>();

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(DocumentSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _detach(oldWidget.controller);
    _attach(widget.controller);
  }

  @override
  void dispose() {
    _detach(widget.controller);
    super.dispose();
  }

  void _clear() => _area.currentState?.selectableRegion.clearSelection();

  void _selectAll() => _area.currentState?.selectableRegion.selectAll();

  void _attach(DocumentController? controller) {
    if (controller == null) return;
    controller
      ..clearSelectionHandler = _clear
      ..selectAllHandler = _selectAll;
  }

  void _detach(DocumentController? controller) {
    if (controller == null) return;
    var owned = false;
    if (controller.clearSelectionHandler == _clear) {
      controller.clearSelectionHandler = null;
      owned = true;
    }
    if (controller.selectAllHandler == _selectAll) controller.selectAllHandler = null;
    // A later area took over; its own selection is what the controller shows.
    if (owned) controller.updateTextSelection(null);
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      key: _area,
      onSelectionChanged: (content) => widget.controller?.updateTextSelection(content?.plainText),
      child: widget.child,
    );
  }
}
