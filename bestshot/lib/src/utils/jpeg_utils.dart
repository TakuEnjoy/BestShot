import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

class JpegUtils {
  /// RAWデータ（DNG, NEF, CR2等）から埋め込みJPEGプレビューを安全・高速に抽出する。
  /// 複数のSOI（FF D8 FF）候補の中から、後方探索とOpenCVデコード検証を行い、
  /// 最大解像度を持つ完全なJPEGストリームを返す。
  static Uint8List? extractEmbeddedJpeg(Uint8List bytes) {
    try {
      int bestStart = -1;
      int bestEnd = -1;
      int maxLen = 0;

      final soiList = <int>[];
      for (int i = 0; i < bytes.length - 3; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
          soiList.add(i);
        }
      }

      for (final start in soiList) {
        int boundary = bytes.length;
        for (final nextSoi in soiList) {
          if (nextSoi > start) {
            boundary = nextSoi;
            break;
          }
        }

        // 次のセグメント境界の手前から後方探索でEOI (FF D9) を検出
        for (int j = boundary - 2; j >= start + 1000; j--) {
          if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
            final len = (j + 2) - start;
            if (len > maxLen) {
              final slice = Uint8List.sublistView(bytes, start, j + 2);
              try {
                final mat = cv.imdecode(slice, cv.IMREAD_COLOR);
                if (mat.rows > 0 && mat.cols > 0) {
                  maxLen = len;
                  bestStart = start;
                  bestEnd = j + 2;
                  mat.dispose();
                  break;
                }
                mat.dispose();
              } catch (_) {}
            }
          }
        }
      }

      if (bestStart >= 0 && bestEnd > bestStart) {
        return Uint8List.sublistView(bytes, bestStart, bestEnd);
      }
    } catch (_) {}
    return null;
  }
}
