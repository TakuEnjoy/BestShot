import 'package:flutter/foundation.dart';
import 'package:image_compare/image_compare.dart' as ic;
import 'package:opencv_dart/opencv_dart.dart' as cv;

class PHashCalculator {
  static String calcEqualizedPHashHexFromMat(cv.Mat mat) {
    try {
      final small = cv.resize(mat, (32, 32));
      final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
      final eq = cv.equalizeHist(gray);

      final pixels = <ic.Pixel>[];
      final data = eq.data;
      for (final v in data) {
        pixels.add(ic.Pixel(v, v, v, 255));
      }

      small.dispose();
      gray.dispose();
      eq.dispose();

      final dynamicPixelList = <dynamic>[...pixels];
      final hex = ic.PerceptualHash().calcPhash(dynamicPixelList);
      return hex.padLeft(16, '0');
    } catch (e, s) {
      debugPrint('Error in calcEqualizedPHashHexFromMat: $e\n$s');
      return '0000000000000000';
    }
  }
}
