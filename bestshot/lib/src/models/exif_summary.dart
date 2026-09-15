class ExifSummary {
  const ExifSummary({
    required this.fNumber,
    required this.shutter,
    required this.iso,
    required this.capturedAt,
    this.focalLength,
    this.cameraModel,
    this.lensModel,
    this.exposureBias,
    this.imageWidth,
    this.imageHeight,
  });

  final String? fNumber;
  final String? shutter;
  final String? iso;
  final DateTime? capturedAt;
  final String? focalLength;
  final String? cameraModel;
  final String? lensModel;
  final String? exposureBias;
  final int? imageWidth;
  final int? imageHeight;

  String? get resolution {
    if (imageWidth != null && imageHeight != null && imageWidth! > 0 && imageHeight! > 0) {
      return '$imageWidth×$imageHeight';
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ExifSummary &&
        other.fNumber == fNumber &&
        other.shutter == shutter &&
        other.iso == iso &&
        other.capturedAt == capturedAt &&
        other.focalLength == focalLength &&
        other.cameraModel == cameraModel &&
        other.lensModel == lensModel &&
        other.exposureBias == exposureBias &&
        other.imageWidth == imageWidth &&
        other.imageHeight == imageHeight;
  }

  @override
  int get hashCode => Object.hash(
        fNumber,
        shutter,
        iso,
        capturedAt,
        focalLength,
        cameraModel,
        lensModel,
        exposureBias,
        imageWidth,
        imageHeight,
      );
}
