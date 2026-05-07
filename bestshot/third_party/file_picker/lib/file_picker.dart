library file_picker;

export './src/file_picker.dart';
export './src/platform_file.dart';
export './src/file_picker_result.dart';
export './src/file_picker_macos.dart';
export './src/linux/file_picker_linux.dart';
export './src/file_picker_io.dart';
// NOTE: This project uses a custom Windows folder picker implementation.
// To keep Android/iOS builds simple and compatible with win32 ^6,
// we don't export FilePicker's Windows FFI implementation here.
export './src/windows/file_picker_windows_stub.dart';
