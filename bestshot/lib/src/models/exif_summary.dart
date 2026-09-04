class ExifSummary {
  ExifSummary({
    required this.fNumber,
    required this.shutter,
    required this.iso,
    required this.capturedAt,
    this.focalLength,
    this.cameraModel,
    this.lensModel,
    this.exposureBias,
  });

  final String? fNumber;
  final String? shutter;
  final String? iso;
  final DateTime? capturedAt;
  final String? focalLength;
  final String? cameraModel;
  final String? lensModel;
  final String? exposureBias;
}
