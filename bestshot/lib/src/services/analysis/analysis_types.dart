import 'dart:typed_data';

enum DetectionMode { standard, portrait }

class AnalyzeInput {
  AnalyzeInput({required this.key, this.displayBytes, this.filePath});

  final String key;
  final Uint8List? displayBytes;
  final String? filePath;
}

class AnalyzeOutput {
  const AnalyzeOutput({
    required this.key,
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
    this.hasFace = false,
    this.faceX = 0,
    this.faceY = 0,
    this.faceW = 0,
    this.faceH = 0,
    this.faceSharpness = 0,
    this.eyeOpenAvg,
    this.eyesClosed = false,
    this.bothEyesDetected = false,
    this.eyeSharpness = -1,
    this.debugGridSharps,
  });

  final String key;
  final String pHashHex;

  /// The score used for grouping/UI (mode-dependent).
  final double sharpness;
  final double exposureScore;
  final int orbRows;
  final int orbCols;
  final Uint8List orbBytes;
  final Float32List orbKeypoints; // [x, y, x, y, ...]
  final Uint8List histogram; // 256 bytes
  final Float32List? hueHistogram; // 180 floats
  final Map<String, Float32List>? embeddings;

  /// Portrait-mode extras.
  final bool hasFace;
  final int faceX;
  final int faceY;
  final int faceW;
  final int faceH;

  /// Laplacian variance computed only within face ROI (0 if none).
  final double faceSharpness;

  /// Average of both eyes open probabilities when available (0..1). -1 if unknown.
  final double? eyeOpenAvg;

  /// True when judged as "eyes closed" in portrait mode.
  final bool eyesClosed;

  /// True when both eyes are confidently detected (platform-dependent).
  final bool bothEyesDetected;

  /// Laplacian variance within eye ROIs (0..1 or absolute variance, -1 if none).
  final double eyeSharpness;

  /// Grid sharpness values (4x4, 16 elements).
  final List<double>? debugGridSharps;
}
