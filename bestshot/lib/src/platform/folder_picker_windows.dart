import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class FolderPickerWindows {
  /// Shows a native folder picker dialog and returns selected folder path.
  /// Returns null when cancelled.
  static String? pickFolder() {
    final hrInit = CoInitializeEx(COINIT_APARTMENTTHREADED);
    // RPC_E_CHANGED_MODE can happen if COM already initialized differently; continue.
    if (hrInit.isError && hrInit != HRESULT(RPC_E_CHANGED_MODE)) {
      throw WindowsException(hrInit);
    }

    try {
      return using((arena) {
        final dialog = arena.com<IFileOpenDialog>(FileOpenDialog);

        final options = dialog.getOptions() | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
        dialog.setOptions(options);
        dialog.setTitle(arena.pcwstr('フォルダを選択'));

        try {
          dialog.show(null);
        } on WindowsException catch (e) {
          if (e.hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
            return null;
          }
          rethrow;
        }

        final item = dialog.getResult();
        if (item == null) return null;

        final pwstr = item.getDisplayName(SIGDN_FILESYSPATH);
        final path = pwstr.toDartString();
        CoTaskMemFree(pwstr);
        return path;
      });
    } finally {
      if (hrInit != HRESULT(RPC_E_CHANGED_MODE)) {
        CoUninitialize();
      }
    }
  }
}

