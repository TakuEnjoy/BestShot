import 'dart:typed_data';

class JpegUtils {
  static Uint8List? extractEmbeddedJpeg(Uint8List bytes) {
    try {
      // 1. マジックナンバーの高速スキャン（SOI: FF D8, EOI: FF D9）
      int bestStart = -1;
      int bestEnd = -1;
      int maxLen = 0;

      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
          // SOI見つけた
          int start = i;
          // EOIを探す（次のSOIが見つかるか、ファイルの終わりまで）
          for (int j = i + 2; j < bytes.length - 1; j++) {
            if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
              int end = j + 2;
              int len = end - start;
              if (len > maxLen) {
                maxLen = len;
                bestStart = start;
                bestEnd = end;
              }
              // 大きなJPEGが見つかったら一旦その範囲をスキップして次を探す
              i = j;
              break;
            }
            // JPEGのセグメントとして不自然に長すぎる場合は中断（例: 50MB以上）
            if (j - start > 50 * 1024 * 1024) break;
          }
        }
      }

      if (bestStart >= 0 && bestEnd > bestStart) {
        return Uint8List.sublistView(bytes, bestStart, bestEnd);
      }
    } catch (_) {
      // 解析失敗時はnullを返す
    }
    return null;
  }
}
