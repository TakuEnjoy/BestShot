import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Derived features only. A damaged or outdated entry is always a cache miss.
class EmbeddingCache {
  EmbeddingCache(this.directory, this.modelSignature, this.lightweight);
  final Directory directory;
  final String modelSignature;
  final bool lightweight;
  static const version = 2; // RGB/ImageNet/NCHW 224, orientation baked.
  static const dimensions = 576;

  String fingerprint(String path, FileStat stat) => jsonEncode([
    version,
    modelSignature,
    lightweight,
    File(path).absolute.path,
    stat.size,
    stat.modified.microsecondsSinceEpoch,
  ]);

  File _file(String path) {
    // A collision cannot return another image: the full fingerprint is checked.
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(
      '$modelSignature|$lightweight|${File(path).absolute.path}',
    )) {
      hash =
          ((hash ^ BigInt.from(byte)) *
              BigInt.parse('100000001b3', radix: 16)) &
          mask;
    }
    return File(
      '${directory.path}${Platform.pathSeparator}${hash.toRadixString(16)}.json',
    );
  }

  Future<Map<String, Float32List>?> read(
    String path,
    String fingerprint,
  ) async {
    try {
      final file = _file(path);
      if (!await file.exists() || await file.length() > 200000) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['fingerprint'] != fingerprint) return null;
      final values = json['embeddings'] as Map<String, dynamic>;
      final requiredKeys = lightweight
          ? ['full', 'center', 'left', 'right']
          : ['full', 'center', 'tl', 'tr', 'bl', 'br'];
      if (values.length != requiredKeys.length) return null;
      final result = <String, Float32List>{};
      for (final key in requiredKeys) {
        final vector = Float32List.fromList(
          (values[key] as List)
              .map((value) => (value as num).toDouble())
              .toList(),
        );
        if (vector.length != dimensions ||
            vector.any((value) => !value.isFinite)) {
          return null;
        }
        final norm = vector.fold<double>(
          0,
          (sum, value) => sum + value * value,
        );
        if ((norm - 1).abs() > 0.01) return null;
        result[key] = vector;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String path,
    String fingerprint,
    Map<String, Float32List> embeddings,
  ) async {
    File? temporary;
    try {
      await directory.create(recursive: true);
      final file = _file(path);
      temporary = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temporary.writeAsString(
        jsonEncode({'fingerprint': fingerprint, 'embeddings': embeddings}),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (_) {
      // Cache I/O must not prevent importing a photo.
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {}
    }
  }
}
