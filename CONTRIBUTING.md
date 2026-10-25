# Contributing to universal_document_viewer

Thanks for helping. Bug reports with a sample file, fixes, new format features and documentation are all welcome.

## Ground rules

- Be kind; see the [Code of Conduct](CODE_OF_CONDUCT.md).
- Security problems (for example a file that crashes or hangs a parser) go to the private channel in [SECURITY.md](SECURITY.md), not to a public issue.
- For anything bigger than a small fix, open an issue first so we can agree on the approach.

## Setup

You need Flutter 3.41 or later (Dart 3.11.4 or later).

```sh
git clone https://github.com/macdipu/universal_document_viewer.git
cd universal_document_viewer
flutter pub get
flutter test
```

The first build or test run downloads PDFium (see below), so it needs network access.

Run the example app to see your change on a device:

```sh
cd example
flutter run
```

## How the package is built

[doc/architecture.md](doc/architecture.md) explains the layers: the format engines, the controllers, the views and `DocumentViewer`, and where a change usually belongs. Read it before a larger change.

### PDFium

The PDF engine binds to PDFium through `dart:ffi`. `hook/build.dart` is a Dart build hook that downloads a prebuilt PDFium for the target platform from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries). The release is pinned, and every archive is checked against a pinned SHA-256 before it is used.

- **Updating PDFium:** change the release and the SHA-256 table in `hook/build.dart` together, then regenerate the bindings.
- **Regenerating the bindings** after a header change, or to bind another PDFium function (add it to the list in the script first): `dart run tool/pdfium/ffigen.dart`. Don't edit `pdfium_bindings.g.dart` by hand.

## Tests

```sh
flutter test                     # everything
flutter test test/word_document_view_test.dart
```

Tests build small documents in memory with the helpers in `package:universal_document_viewer/testing.dart` (`buildDocx`, `buildXlsx`, `buildPptx`). Prefer those for a focused case.

Some tests read real files from `test/fixtures/`. These files are written by independent tools (python-docx, openpyxl, reportlab), so the readers aren't only tested against files they could have written themselves. To change a fixture, edit its script and regenerate:

```sh
python3 test/fixtures/word/generate.py     # needs python-docx
python3 test/fixtures/sheets/generate.py   # needs openpyxl
python3 test/fixtures/pdf/generate.py      # needs reportlab
```

Commit the script change and the regenerated files together.

**A bug fix comes with a test that fails without it.** For a parser bug, the smallest document that shows it is best. Build it with `testing.dart`, or add it as a fixture if it's a real-world file you're allowed to share.

## Style

- `flutter analyze` must be clean. The lints are `flutter_lints`, set in `analysis_options.yaml`.
- Format with `dart format .` (120 columns, set in `analysis_options.yaml`).
- Document every public member with a `///` comment that says what it does and why you would use it.
- Controllers are plain `ChangeNotifier`s: no state-management package, no storage. Positions and preferences belong to the app.
- Views show a document and nothing else: no toolbars, dialogs or English text built into a format's view. Ready-made UI lives in `DocumentViewer`.
- Parsing runs off the UI isolate. Anything that reads a file checks it first (`ZipSafetyGuard` for Office files).
- Don't add a dependency unless it's needed. Native PDF engines, web views and platform document viewers are out of scope.

## Pull requests

1. Branch from `main`.
2. Keep each PR to one change. Separate refactors from behaviour changes.
3. Make sure `dart format --set-exit-if-changed .`, `flutter analyze` and `flutter test` pass. CI runs the same checks.
4. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything a user of the package would notice.
5. Fill in the PR template: what changed, why, and how you tested it (including on which platforms, for anything visual).

## Releases

The maintainer publishes to pub.dev. A release moves **Unreleased** in the CHANGELOG under the new version and bumps `version` in `pubspec.yaml`. Before 1.0, a minor version (0.x.0) may break the API; the CHANGELOG then says how to migrate.
