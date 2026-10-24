import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

/// Provides PDFium (Google's PDF engine, BSD-3-Clause) as the
/// `package:universal_document_viewer/libpdfium` code asset, which the PDF engine's
/// bindings (`lib/src/engines/pdfium/`) bind to.
///
/// The library comes prebuilt from bblanchon/pdfium-binaries, at one
/// pinned release. Each archive's SHA-256 is pinned too: a download (or a
/// cached copy) that doesn't match is rejected, never used.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final binary = _Binary.forTarget(code);
    final library = File.fromUri(
      input.outputDirectoryShared.resolve('pdfium-$_build/${binary.archive}/${binary.libraryName}'),
    );
    final stamp = File('${library.path}.sha256');
    // A cached library is reused only if it came from the pinned archive.
    if (!(await library.exists() && await stamp.exists() && (await stamp.readAsString()) == binary.sha256)) {
      await _download(binary, library, stamp);
    }
    output.assets.code.add(
      CodeAsset(package: input.packageName, name: 'libpdfium', linkMode: DynamicLoadingBundled(), file: library.uri),
    );
  });
}

/// PDFium 157.0.8086 (bblanchon/pdfium-binaries `chromium/8086`,
/// 2026-10-05).
const _build = '8086';
const _release = 'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F$_build';

/// Archive name -> SHA-256, recorded 2026-10-24.
const _hashes = {
  'pdfium-android-arm': 'fdf3a2b329759f5ba8a9997329ae79dad3570b1d90ecde60b5a56f1a9ff6a98c',
  'pdfium-android-arm64': 'f6ea29495d64795b9af61e41768030795b45f82a21415498ee4ab2c61e135756',
  'pdfium-android-x64': '772870e7ed846097d779aa0163f8abfd08a13257e16edf0e1cd1a364f11c8c3c',
  'pdfium-android-x86': '721154d013c615098579cf9169203a39a25d93b0dbceb09719f692481a3dcda8',
  'pdfium-ios-device-arm64': 'a25c134cf778c9067082fee8b42cbff8d1561a2e1bb4b613c635e8f4a68e1356',
  'pdfium-ios-simulator-arm64': 'dced2ba4fd37b9c39f363039efb9574f1c2b0171186d3a32eccaf0391180b13f',
  'pdfium-ios-simulator-x64': '65f203cf3a74d7970fd2be9730981050d35f17de5ef65a1df2291ac0d335efda',
  'pdfium-linux-arm64': 'e7e2fe4686925618330103cb167950aca5a84bb00fd977a41b86be59dd1480a2',
  'pdfium-linux-x64': '588577cf52dabc1a444988bac841920df54cc2f141801424de97ab04f4fbb935',
  'pdfium-mac-arm64': 'e98679e052c07edbb5a627980902abb823d4b3f35744d877bd21668bd9fc13ab',
  'pdfium-mac-x64': '933a85a138f6027243c56bff8676375c33ceeb767401389415ffc44d689ca85d',
  'pdfium-win-arm64': '1799b8034e6d64946fec0ae79f3edfc8ba58ccd80c70a46194803b1eba408344',
  'pdfium-win-x64': '1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d',
};

/// The archive and the library inside it for one build target.
class _Binary {
  const _Binary(this.archive, this.memberPath, this.libraryName, this.sha256);

  final String archive;
  final String memberPath;
  final String libraryName;
  final String sha256;

  factory _Binary.forTarget(CodeConfig code) {
    final arch = switch (code.targetArchitecture) {
      Architecture.arm => 'arm',
      Architecture.arm64 => 'arm64',
      Architecture.ia32 => 'x86',
      Architecture.x64 => 'x64',
      final other => throw UnsupportedError('PDFium: unsupported architecture $other'),
    };
    final (platform, member, name) = switch (code.targetOS) {
      OS.android => ('android', 'lib/libpdfium.so', 'libpdfium.so'),
      OS.linux => ('linux', 'lib/libpdfium.so', 'libpdfium.so'),
      OS.macOS => ('mac', 'lib/libpdfium.dylib', 'libpdfium.dylib'),
      OS.windows => ('win', 'bin/pdfium.dll', 'pdfium.dll'),
      OS.iOS => (
          code.iOS.targetSdk == IOSSdk.iPhoneSimulator ? 'ios-simulator' : 'ios-device',
          'lib/libpdfium.dylib',
          'libpdfium.dylib',
        ),
      final other => throw UnsupportedError('PDFium: unsupported platform $other'),
    };
    final archive = 'pdfium-$platform-$arch';
    final sha256 = _hashes[archive] ?? (throw UnsupportedError('PDFium: no pinned build for $archive'));
    return _Binary(archive, member, name, sha256);
  }
}

Future<void> _download(_Binary binary, File library, File stamp) async {
  final uri = Uri.parse('$_release/${binary.archive}.tgz');
  // Behind a proxy (CI, corporate networks) the standard proxy variables
  // are honoured, as other build tools do.
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(minutes: 5));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('PDFium download failed (${response.statusCode})', uri: uri);
    }
    // A stalled body fails the build rather than hanging it.
    final bytes = await response
        .fold<BytesBuilder>(BytesBuilder(copy: false), (b, chunk) => b..add(chunk))
        .timeout(const Duration(minutes: 10));
    final data = bytes.takeBytes();
    final actual = sha256.convert(data).toString();
    if (actual != binary.sha256) {
      throw StateError('PDFium archive ${binary.archive}.tgz has SHA-256 $actual, expected ${binary.sha256}');
    }
    final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(data));
    final member = archive.findFile(binary.memberPath);
    final content = member?.readBytes();
    if (content == null) throw StateError('PDFium archive ${binary.archive}.tgz has no ${binary.memberPath}');
    await library.parent.create(recursive: true);
    // Write then rename, so a half-written file is never picked up.
    final partial = File('${library.path}.partial');
    await partial.writeAsBytes(content, flush: true);
    await partial.rename(library.path);
    await stamp.writeAsString(binary.sha256);
  } finally {
    client.close(force: true);
  }
}
