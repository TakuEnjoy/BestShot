class ExifSummary {
  ExifSummary({
    required this.fNumber,
    required this.shutter,
    required this.iso,
    required this.capturedAt,
  });

  final String? fNumber;
  final String? shutter;
  final String? iso;
  final DateTime? capturedAt;
}
