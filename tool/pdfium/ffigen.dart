// Generates universal_document_viewer's PDFium bindings: only the functions the PDF
// engine calls, as @Native externals bound to the build hook's code asset.
//
//   dart run tool/pdfium/ffigen.dart
//
// Headers: bblanchon/pdfium-binaries chromium/8086 (PDFium 157.0.8086), in
// tool/pdfium/include (BSD-3-Clause, see tool/pdfium/LICENSE).
import 'dart:io';

import 'package:ffigen/ffigen.dart';

const _functions = {
  'FPDF_InitLibrary',
  'FPDF_DestroyLibrary',
  'FPDF_LoadDocument',
  'FPDF_LoadMemDocument64',
  'FPDF_GetLastError',
  'FPDF_CloseDocument',
  'FPDF_GetPageCount',
  'FPDF_LoadPage',
  'FPDF_ClosePage',
  'FPDF_GetPageWidthF',
  'FPDF_GetPageHeightF',
  'FPDF_GetPageBoundingBox',
  'FPDF_GetPageSizeByIndexF',
  'FPDFBitmap_CreateEx',
  'FPDFBitmap_FillRect',
  'FPDFBitmap_Destroy',
  'FPDF_RenderPageBitmap',
  'FPDFText_LoadPage',
  'FPDFText_ClosePage',
  'FPDFText_CountChars',
  'FPDFText_GetUnicode',
  'FPDFText_GetCharBox',
  'FPDFLink_LoadWebLinks',
  'FPDFLink_CountWebLinks',
  'FPDFLink_GetURL',
  'FPDFLink_CountRects',
  'FPDFLink_GetRect',
  'FPDFLink_CloseWebLinks',
  'FPDFPage_GetRotation',
  'FPDFLink_Enumerate',
  'FPDFLink_GetAnnotRect',
  'FPDFLink_GetAction',
  'FPDFLink_GetDest',
  'FPDFAction_GetType',
  'FPDFAction_GetDest',
  'FPDFAction_GetURIPath',
  'FPDFDest_GetDestPageIndex',
};

/// Structs the engine reads; other handle types stay opaque.
const _structs = {'_FS_RECTF_': 'FS_RECTF', 'FS_SIZEF_': 'FS_SIZEF'};

final _macros = RegExp(r'^(FPDF_ANNOT|FPDF_LCD_TEXT|FPDF_REVERSE_BYTE_ORDER|FPDFBitmap_BGRA|FPDF_ERR_\w+|PDFACTION_\w+)$');

Future<void> main() async {
  final root = Platform.script.resolve('../../');
  final include = root.resolve('tool/pdfium/include/');
  await FfiGenerator(
    input: Input(
      entryPoints: [
        for (final header in ['fpdfview.h', 'fpdf_text.h', 'fpdf_doc.h', 'fpdf_edit.h']) include.resolve(header),
      ],
      compilerOptions: ['-I${include.toFilePath()}'],
    ),
    output: Output(
      dart: DartOutput(path: root.resolve('lib/src/engines/pdfium/pdfium_bindings.g.dart')),
      style: const NativeExternalBindings(assetId: 'package:universal_document_viewer/libpdfium'),
      preamble: '// Generated from PDFium\'s public headers (BSD-3-Clause, see tool/pdfium/LICENSE)\n'
          '// by tool/pdfium/ffigen.dart. Do not edit; regenerate instead.\n'
          '// ignore_for_file: type=lint, unused_field, unused_element\n',
    ),
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = _functions.contains(node.originalName),
        struct: (node) {
          if (_structs[node.originalName] case final name?) {
            node.isIncluded = true;
            node.name = name;
          }
        },
        macroConstant: (node) => node.isIncluded = _macros.hasMatch(node.originalName),
      ),
    ],
  ).generate();
}
