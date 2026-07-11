import 'dart:io';

void main() {
  final files = [
    'lib/src/services/analysis/analyzer_isolate.dart',
    'lib/src/services/analysis/focus_mask_service.dart',
    'lib/src/services/analysis/sharpness_analyzer.dart',
    'lib/src/services/deleting/delete_service.dart'
  ];

  for (var path in files) {
    final file = File(path);
    if (!file.existsSync()) continue;
    var content = file.readAsStringSync();
    
    if (content.contains('print(')) {
      if (!content.contains("import 'dart:developer'")) {
        content = content.replaceFirst(
            RegExp(r"^import '.*?;", multiLine: true), 
            "import 'dart:developer' as developer;\n" + RegExp(r"^import '.*?;", multiLine: true).firstMatch(content)!.group(0)!);
      }
      content = content.replaceAll(RegExp(r'\bprint\('), 'developer.log(');
      file.writeAsStringSync(content);
      print("Updated \$path");
    }
  }
}
