import 'dart:io';

void main() {
  final file = File('lib/src/models/photo_entry.dart');
  var content = file.readAsStringSync();
  
  // ensure foundation is imported if we use ValueGetter
  if (!content.contains('package:flutter/foundation.dart')) {
    content = content.replaceFirst("import 'dart:typed_data';", "import 'dart:typed_data';\nimport 'package:flutter/foundation.dart';");
  }

  final newMethods = """
  PhotoEntry copyWith({
    String? key,
    PhotoOrigin? origin,
    Uint8List? displayBytes,
    ValueGetter<String?>? assetId,
    ValueGetter<String?>? filePath,
    String? pHashHex,
    double? sharpness,
    double? exposureScore,
    int? orbRows,
    int? orbCols,
    Uint8List? orbBytes,
    Uint8List? histogram,
    ValueGetter<Float32List?>? hueHistogram,
    ValueGetter<ExifSummary?>? exif,
    List<SemanticObject>? semanticObjects,
    double? faceQualityScore,
    PortraitAnalysis? portrait,
    ValueGetter<List<double>?>? debugGridSharps,
  }) {
    return PhotoEntry(
      key: key ?? this.key,
      origin: origin ?? this.origin,
      displayBytes: displayBytes ?? this.displayBytes,
      assetId: assetId != null ? assetId() : this.assetId,
      filePath: filePath != null ? filePath() : this.filePath,
      pHashHex: pHashHex ?? this.pHashHex,
      sharpness: sharpness ?? this.sharpness,
      exposureScore: exposureScore ?? this.exposureScore,
      orbRows: orbRows ?? this.orbRows,
      orbCols: orbCols ?? this.orbCols,
      orbBytes: orbBytes ?? this.orbBytes,
      histogram: histogram ?? this.histogram,
      hueHistogram: hueHistogram != null ? hueHistogram() : this.hueHistogram,
      exif: exif != null ? exif() : this.exif,
      semanticObjects: semanticObjects ?? this.semanticObjects,
      faceQualityScore: faceQualityScore ?? this.faceQualityScore,
      portrait: portrait ?? this.portrait,
      debugGridSharps: debugGridSharps != null ? debugGridSharps() : this.debugGridSharps,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PhotoEntry &&
        other.key == key &&
        other.origin == origin &&
        listEquals(other.displayBytes, displayBytes) &&
        other.assetId == assetId &&
        other.filePath == filePath &&
        other.pHashHex == pHashHex &&
        other.sharpness == sharpness &&
        other.exposureScore == exposureScore &&
        other.orbRows == orbRows &&
        other.orbCols == orbCols &&
        listEquals(other.orbBytes, orbBytes) &&
        listEquals(other.histogram, histogram) &&
        listEquals(other.hueHistogram, hueHistogram) &&
        other.exif == exif &&
        listEquals(other.semanticObjects, semanticObjects) &&
        other.faceQualityScore == faceQualityScore &&
        other.portrait == portrait &&
        listEquals(other.debugGridSharps, debugGridSharps);
  }

  @override
  int get hashCode {
    return key.hashCode ^
        origin.hashCode ^
        Object.hashAll(displayBytes) ^
        assetId.hashCode ^
        filePath.hashCode ^
        pHashHex.hashCode ^
        sharpness.hashCode ^
        exposureScore.hashCode ^
        orbRows.hashCode ^
        orbCols.hashCode ^
        Object.hashAll(orbBytes) ^
        Object.hashAll(histogram) ^
        (hueHistogram != null ? Object.hashAll(hueHistogram!) : 0) ^
        exif.hashCode ^
        Object.hashAll(semanticObjects) ^
        faceQualityScore.hashCode ^
        portrait.hashCode ^
        (debugGridSharps != null ? Object.hashAll(debugGridSharps!) : 0);
  }

  @override
  String toString() {
    return 'PhotoEntry(key: \$key, origin: \$origin, sharpness: \$sharpness, exposure: \$exposureScore, pHashHex: \$pHashHex)';
  }
}
""";

  final oldCopyWithRegExp = RegExp(r'  PhotoEntry copyWith\(\{[\s\S]*?\}\) \{[\s\S]*?return PhotoEntry\([\s\S]*?\);\n  \}\n\}');
  if (oldCopyWithRegExp.hasMatch(content)) {
    content = content.replaceFirst(oldCopyWithRegExp, newMethods);
  } else {
    print("Could not find old copyWith");
    exit(1);
  }
  
  file.writeAsStringSync(content);
}
