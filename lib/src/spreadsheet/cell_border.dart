import 'package:flutter/widgets.dart';

import '../engines/sheets/workbook.dart';

/// A cell's border: the file's lines where it drew them (automatic ones in
/// [automatic], so they show on a dark theme too), else the thin
/// [gridline].
Border cellBorder(CellBorders borders, {required Color gridline, required Color automatic, double zoom = 1}) {
  BorderSide side(BorderLine? line) => line == null
      ? BorderSide(color: gridline, width: 0.5)
      : BorderSide(
          color: line.color == null ? automatic : Color(line.color!),
          // Each cell draws its own sides, so a line both neighbours
          // carry is drawn twice: draw each at a bit over half weight.
          width: line.style.width * 0.6 * zoom.clamp(0.5, 2.0),
        );
  return Border(
    left: side(borders.left),
    right: side(borders.right),
    top: side(borders.top),
    bottom: side(borders.bottom),
  );
}
