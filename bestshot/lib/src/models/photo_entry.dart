import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'exif_summary.dart';
import 'semantic_object.dart';
import 'portrait_analysis.dart';
export 'exif_summary.dart';
export 'semantic_object.dart';
export 'portrait_analysis.dart';

enum PhotoOrigin { deviceAsset, filePath }

/// スコア算出の詳細内訳（XAI / デバッグ可視化用）
class ScoreExplanation {
  const ScoreExplanation({
    required this.totalScore,
    required this.rawSharpness,
    required this.effectiveSharpness,
    required this.normalizedSharpness,
    required this.exposureScore,
    required this.faceQualityScore,
    required this.ruleName,
    required this.formulaText,
  });

  final double totalScore;
  final double rawSharpness;
  final double effectiveSharpness;
  final double normalizedSharpness;
  final double exposureScore;
  final double faceQualityScore;
  final String ruleName;
  final String formulaText;
}

/// グループ化の判定根拠（XAI / デバッグ可視化用）
class GroupMatchExplanation {
  const GroupMatchExplanation({
    required this.matchType,
    required this.description,
    this.category,
    this.diffSeconds,
    this.pHashDistance,
    this.colorDistance,
    this.orbMatches,
    this.inliers,
    this.orbInlierRatio,
    this.embeddingSimilarity,
    this.cropPair,
    this.semanticMatch = false,
    this.confidence = 1.0,
    this.needsReview = false,
    this.referenceKey,
  });

  final String matchType;
  final String description;
  final String? category;
  final double? diffSeconds;
  final int? pHashDistance;
  final double? colorDistance;
  final int? orbMatches;
  final int? inliers;
  final double? orbInlierRatio;
  final double? embeddingSimilarity;
  final String? cropPair;
  final bool semanticMatch;
  final double confidence;
  final bool needsReview;
  final String? referenceKey;
}

class PhotoEntry {
  PhotoEntry({
    required this.key,
    required this.origin,
    required this.displayBytes,
    this.assetId,
    this.filePath,
    required this.pHashHex,
    required this.sharpness,
    required this.exposureScore,
    required this.orbRows,
    required this.orbCols,
    required this.orbBytes,
    required this.orbKeypoints,
    required this.histogram,
    this.hueHistogram,
    this.embeddings,
    this.exif,
    this.semanticObjects = const [],
    this.faceQualityScore = 0,
    this.portrait = const PortraitAnalysis(),
    this.debugGridSharps,
    this.scoreExplanation,
    this.groupExplanation,
  });

  /// Unique key across all imported items.
  final String key;

  final PhotoOrigin origin;

  /// Thumbnail bytes (JPEG/PNG) for grid display.
  final Uint8List displayBytes;

  /// `photo_manager` AssetEntity id when [origin] == deviceAsset.
  final String? assetId;

  /// File path when [origin] == filePath.
  final String? filePath;

  /// pHash (after grayscale + histogram equalization), 64-bit as 16 hex chars.
  final String pHashHex;

  /// Laplacian variance (higher => sharper).
  final double sharpness;

  /// 0..1, higher is better (less clipping + mean near mid).
  final double exposureScore;

  /// ORB descriptors: rows x cols bytes (cols usually 32).
  final int orbRows;
  final int orbCols;
  final Uint8List orbBytes;
  final Float32List orbKeypoints;

  /// Luma histogram (256 entries).
  final Uint8List histogram;

  /// HSV Hue histogram (180 entries).
  final Float32List? hueHistogram;

  /// Embeddings for multi-crop (e.g. 'full', 'center', 'tl', 'tr', 'bl', 'br').
  final Map<String, Float32List>? embeddings;

  /// Optional EXIF summary (F/SS/ISO).
  final ExifSummary? exif;

  /// ML Kit object detection results (if available).
  final List<SemanticObject> semanticObjects;

  /// ML Kit face-based preference (higher => better expression/eyes).
  final double faceQualityScore;

  /// Portrait-mode analysis results.
  final PortraitAnalysis portrait;

  /// Debug info: Laplacian variance for each of the 4x4 grid cells.
  final List<double>? debugGridSharps;

  /// スコア算出根拠（デバッグ・XAI表示用）
  final ScoreExplanation? scoreExplanation;

  /// グループ化判定根拠（デバッグ・XAI表示用）
  final GroupMatchExplanation? groupExplanation;

  DateTime? get capturedAt => exif?.capturedAt;

  /// Focus point in normalized coordinates (0.0 .. 1.0) derived from local Laplacian variance.
  Offset? get focusPoint {
    final sharps = debugGridSharps;
    if (sharps == null || sharps.length != 16) return null;

    int bestIdx = 0;
    double maxVal = -1;
    for (int i = 0; i < 16; i++) {
      if (sharps[i] > maxVal) {
        maxVal = sharps[i];
        bestIdx = i;
      }
    }
    if (maxVal <= 0) return null;

    // Calculate center of mass for top-3 sharpest cells for sub-grid accuracy
    final entries = List.generate(16, (i) => MapEntry(i, sharps[i]))
      ..sort((a, b) => b.value.compareTo(a.value));

    double totalWeight = 0;
    double weightedX = 0;
    double weightedY = 0;
    final topN = entries.take(3);
    for (final e in topN) {
      if (e.value <= 0) continue;
      final c = e.key % 4;
      final r = e.key ~/ 4;
      final cx = (c + 0.5) / 4.0;
      final cy = (r + 0.5) / 4.0;
      // Exponential weighting to favor the absolute sharpest region
      final w = e.value * e.value;
      weightedX += cx * w;
      weightedY += cy * w;
      totalWeight += w;
    }

    if (totalWeight <= 0) {
      final c = bestIdx % 4;
      final r = bestIdx ~/ 4;
      return Offset((c + 0.5) / 4.0, (r + 0.5) / 4.0);
    }

    return Offset(
      (weightedX / totalWeight).clamp(0.08, 0.92),
      (weightedY / totalWeight).clamp(0.08, 0.92),
    );
  }

  String get exifText {
    final e = exif;
    if (e == null) return '';
    final parts = <String>[];

    // Add captured time if available
    if (e.capturedAt != null) {
      final t = e.capturedAt!;
      final timeStr =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
      parts.add(timeStr);
    }

    if (e.fNumber != null && e.fNumber!.isNotEmpty) parts.add('F${e.fNumber}');
    if (e.shutter != null && e.shutter!.isNotEmpty) parts.add(e.shutter!);
    if (e.iso != null && e.iso!.isNotEmpty) parts.add('ISO${e.iso}');
    if (e.focalLength != null && e.focalLength!.isNotEmpty) parts.add(e.focalLength!);
    return parts.join('  ');
  }

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
    Float32List? orbKeypoints,
    Uint8List? histogram,
    ValueGetter<Float32List?>? hueHistogram,
    ValueGetter<Map<String, Float32List>?>? embeddings,
    ValueGetter<ExifSummary?>? exif,
    List<SemanticObject>? semanticObjects,
    double? faceQualityScore,
    PortraitAnalysis? portrait,
    ValueGetter<List<double>?>? debugGridSharps,
    ValueGetter<ScoreExplanation?>? scoreExplanation,
    ValueGetter<GroupMatchExplanation?>? groupExplanation,
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
      orbKeypoints: orbKeypoints ?? this.orbKeypoints,
      histogram: histogram ?? this.histogram,
      hueHistogram: hueHistogram != null ? hueHistogram() : this.hueHistogram,
      embeddings: embeddings != null ? embeddings() : this.embeddings,
      exif: exif != null ? exif() : this.exif,
      semanticObjects: semanticObjects ?? this.semanticObjects,
      faceQualityScore: faceQualityScore ?? this.faceQualityScore,
      portrait: portrait ?? this.portrait,
      debugGridSharps: debugGridSharps != null
          ? debugGridSharps()
          : this.debugGridSharps,
      scoreExplanation: scoreExplanation != null
          ? scoreExplanation()
          : this.scoreExplanation,
      groupExplanation: groupExplanation != null
          ? groupExplanation()
          : this.groupExplanation,
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
        listEquals(other.orbKeypoints, orbKeypoints) &&
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
        Object.hashAll(orbKeypoints) ^
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
    return 'PhotoEntry(key: $key, origin: $origin, sharpness: $sharpness, exposure: $exposureScore, pHashHex: $pHashHex)';
  }
}
