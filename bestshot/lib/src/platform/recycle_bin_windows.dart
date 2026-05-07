import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class RecycleBinWindows {
  /// Moves [filePaths] to the Recycle Bin.
  static void moveToRecycleBin(List<String> filePaths) {
    if (filePaths.isEmpty) return;

    // SHFileOperation expects a double-null terminated list of paths.
    final buffer = '${filePaths.join('\u0000')}\u0000\u0000';
    final pFrom = buffer.toNativeUtf16();

    final op = calloc<SHFILEOPSTRUCT>()
      ..ref.wFunc = FO_DELETE
      ..ref.pFrom = PWSTR(pFrom)
      ..ref.fFlags = (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT);

    try {
      final result = SHFileOperation(op);
      if (result.value != 0) {
        throw WindowsException(HRESULT_FROM_WIN32(WIN32_ERROR(result.value)));
      }
      if (op.ref.fAnyOperationsAborted) {
        throw WindowsException(HRESULT(E_ABORT));
      }
    } finally {
      calloc.free(op);
      calloc.free(pFrom);
    }
  }
}

