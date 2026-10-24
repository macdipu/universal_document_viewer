# Notices

## universal_document_viewer's own engines
Engines written for universal_document_viewer from the published file-format specifications and library APIs (CR-OWN-ENGINES). They contain no code from other Dart packages:
- `lib/src/engines/ooxml/`: the Office package layer (ECMA-376 Part 2).
- `lib/src/engines/sheets/`: `.xlsx` (ECMA-376 SpreadsheetML) and CSV (RFC 4180). These replaced excel_plus and csv_plus on 2026-10-24.
- `lib/src/engines/word/`: `.docx` (ECMA-376 WordprocessingML). It replaced docx_file_viewer and docx_creator on 2026-10-24.
- `lib/src/engines/pdfium/` and `lib/src/pdf_reader/`: universal_document_viewer's own PDF engine (bindings to PDFium, run in a worker isolate) and PDF viewer. They replaced the pdfrx family (pdfrx, pdfrx_engine, pdfium_dart, pdfium_flutter) on 2026-10-24.

## PDFium
PDF rendering uses [PDFium](https://pdfium.googlesource.com/pdfium/), Google's PDF engine (Copyright 2014 The PDFium Authors, BSD-3-Clause).

PDFium is not part of this source tree. `hook/build.dart` downloads it at build time as a prebuilt binary from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries), release `chromium/8086` (PDFium 157.0.8086), and checks each archive against a pinned SHA-256. The library is then bundled into the app.

The PDFium C headers in `tool/pdfium/` (used to generate the bindings) are covered by PDFium's licence in `tool/pdfium/LICENSE`.

The licence texts below come from the `licenses/` folder of the release archives (copied from `pdfium-android-arm64.tgz`) and are in `licenses/pdfium/`. They cover PDFium and the third-party components compiled into the binary:

| Component | License | File in `licenses/pdfium/` |
|---|---|---|
| PDFium | BSD-3-Clause (some parts Apache-2.0) | `pdfium.txt` |
| Abseil | Apache-2.0 | `abseil.txt` |
| Anti-Grain Geometry 2.3 | AGG license (permissive) | `agg23.txt` |
| Catapult (Chromium) | BSD-3-Clause | `catapult.txt` |
| cpu_features | Apache-2.0 | `cpu_features.txt` |
| Dragonbox | Apache-2.0 with LLVM Exceptions, or Boost Software License 1.0 | `dragonbox-Apache2-LLVM.txt`, `dragonbox-Boost.txt` |
| fast_float | MIT | `fast_float.txt` |
| FreeType | FreeType License (FTL) | `freetype.txt` |
| HarfBuzz | Old MIT | `harfbuzz.txt` |
| ICU | Unicode License V3 | `icu.txt` |
| Little CMS | MIT | `lcms.txt` |
| libjpeg-turbo | IJG License and BSD-3-Clause (SIMD code zlib) | `libjpeg_turbo.md`, `libjpeg_turbo.ijg` |
| OpenJPEG | BSD-2-Clause | `libopenjpeg.txt` |
| libpng | PNG Reference Library License v2 | `libpng.txt` |
| libunwind (LLVM) | Apache-2.0 with LLVM Exceptions | `libunwind.txt` |
| LLVM libc | Apache-2.0 with LLVM Exceptions | `llvm-libc.txt` |
| simdutf | MIT | `simdutf.txt` |
| zlib | zlib License | `zlib.txt` |
