import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// The bytes aren't a readable Office package.
class OpcFormatException implements Exception {
  const OpcFormatException(this.message);
  final String message;

  @override
  String toString() => 'OpcFormatException: $message';
}

/// A link from one part to another (ECMA-376 Part 2, §9.3).
class OpcRelationship {
  const OpcRelationship({required this.id, required this.type, required this.target, this.external = false});

  final String id;

  /// The full relationship type URI; compare with [isOfType].
  final String type;

  /// For an internal relationship, the target part's name, resolved against
  /// the source part (no leading `/`). For an external one, the URI as
  /// written.
  final String target;

  final bool external;

  /// Whether [type] ends in `/kind`, e.g. `officeDocument`, `worksheet`,
  /// `styles`. Matches both the transitional and strict namespaces.
  bool isOfType(String kind) => type.endsWith('/$kind');
}

/// An Office Open XML package (`.docx`, `.xlsx`, `.pptx`): a ZIP of parts
/// tied together by relationships (Open Packaging Conventions, ECMA-376
/// Part 2).
///
/// Parts are looked up case-insensitively, as OPC requires. Each part is
/// inflated only when read, and never past the size the ZIP declares for it
/// or [maxPartBytes]: `ZipSafetyGuard` vets only the declared sizes, so a
/// part forged to declare 10 bytes must not be let inflate to hundreds of
/// MB. `archive` 4.5 bounds this itself; the kit doesn't rely on it.
class OpcPackage {
  OpcPackage._(this._parts);

  /// Largest part read, whatever its declared size. Well past any real
  /// slide, sheet or picture, and a first-pass, adjustable ceiling like
  /// `ZipSafetyGuard`'s.
  static const int maxPartBytes = 256 * 1024 * 1024;

  final Map<String, ArchiveFile> _parts;

  /// Opens [bytes]. Throws [OpcFormatException] when they aren't a ZIP.
  factory OpcPackage.decode(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const OpcFormatException('Not a ZIP package');
    }
    return OpcPackage._({
      for (final file in archive.files)
        if (file.isFile) _key(file.name): file,
    });
  }

  static String _key(String partName) => (partName.startsWith('/') ? partName.substring(1) : partName).toLowerCase();

  bool contains(String partName) => _parts.containsKey(_key(partName));

  /// The part's inflated bytes; null when it doesn't exist. Throws
  /// [OpcFormatException] for a part that is damaged, or larger than its
  /// declared size or [maxPartBytes].
  Uint8List? readBytes(String partName) {
    final file = _parts[_key(partName)];
    if (file == null) return null;
    if (file.size > maxPartBytes) throw OpcFormatException('$partName is too large');
    // Inflated into a fresh buffer rather than through `ArchiveFile.readBytes`,
    // which would also keep a copy cached on the archive for its lifetime.
    final output = _BoundedOutput(file.size);
    try {
      file.decompress(output);
    } catch (_) {
      throw OpcFormatException('$partName is damaged or larger than it declares');
    }
    return output.getBytes();
  }

  /// The part as UTF-8 text (invalid bytes replaced, not fatal).
  String? readText(String partName) {
    final content = readBytes(partName);
    return content == null ? null : utf8.decode(content, allowMalformed: true);
  }

  /// The part as an XML document. Throws [OpcFormatException] on malformed
  /// XML; null when the part doesn't exist.
  XmlDocument? readXml(String partName) {
    final text = readText(partName);
    if (text == null) return null;
    try {
      return XmlDocument.parse(text);
    } on XmlException {
      throw OpcFormatException('Malformed XML in $partName');
    }
  }

  /// The relationships of [sourcePart]; `''` for the package itself
  /// (`_rels/.rels`). Empty when the part has none.
  List<OpcRelationship> relationshipsOf(String sourcePart) {
    final source = _key(sourcePart);
    final relsPart = source.isEmpty
        ? '_rels/.rels'
        : p.posix.join(p.posix.dirname(source), '_rels', '${p.posix.basename(source)}.rels');
    final doc = readXml(relsPart);
    if (doc == null) return const [];
    final baseDir = source.isEmpty ? '' : p.posix.dirname(sourcePart.startsWith('/') ? sourcePart.substring(1) : sourcePart);
    return [
      for (final rel in doc.rootElement.childElements)
        if (rel.getAttribute('Id') case final id?)
          if (rel.getAttribute('Target') case final target?)
            _relationship(id, rel.getAttribute('Type') ?? '', target, rel.getAttribute('TargetMode') == 'External', baseDir),
    ];
  }

  static OpcRelationship _relationship(String id, String type, String target, bool external, String baseDir) {
    if (external) return OpcRelationship(id: id, type: type, target: target, external: true);
    final resolved = target.startsWith('/') ? target.substring(1) : p.posix.join(baseDir, target);
    return OpcRelationship(id: id, type: type, target: p.posix.normalize(resolved));
  }

  /// The first internal relationship of [sourcePart] of the given kind
  /// (see [OpcRelationship.isOfType]).
  OpcRelationship? relationshipOfType(String sourcePart, String kind) =>
      relationshipsOf(sourcePart).where((r) => !r.external && r.isOfType(kind)).firstOrNull;

  /// The package's main part (`word/document.xml`, `xl/workbook.xml`,
  /// `ppt/presentation.xml`...), or null when the package names none.
  String? get mainPart => relationshipOfType('', 'officeDocument')?.target;
}

/// An in-memory output that refuses to grow past [_limit] bytes: each write
/// is checked before the buffer is grown for it.
class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this._limit) : super(size: _limit.clamp(1, OutputMemoryStream.defaultBufferSize));

  final int _limit;

  void _reserve(int count) {
    if (length + count > _limit) throw const OpcFormatException('Part inflates past its declared size');
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    super.writeBackReference(distance, count);
  }
}
