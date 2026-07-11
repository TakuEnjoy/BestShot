import 'dart:io';

void main() {
  final file = File('lib/src/services/analysis/analyzer_isolate.dart');
  var content = file.readAsStringSync();

  content = content.replaceAll('WorkerMessage', '_WorkerMessage');
  content = content.replaceAll('WorkerInitMessage', '_WorkerInitMessage');
  content = content.replaceAll('WorkerResultMessage', '_WorkerResultMessage');
  content = content.replaceAll('WorkerDoneMessage', '_WorkerDoneMessage');
  content = content.replaceAll('MainMessage', '_MainMessage');
  content = content.replaceAll('MainTaskMessage', '_MainTaskMessage');
  content = content.replaceAll('MainShutdownMessage', '_MainShutdownMessage');
  
  content = content.replaceAll('__WorkerMessage', '_WorkerMessage');
  content = content.replaceAll('__WorkerInitMessage', '_WorkerInitMessage');
  content = content.replaceAll('__WorkerResultMessage', '_WorkerResultMessage');
  content = content.replaceAll('__WorkerDoneMessage', '_WorkerDoneMessage');
  content = content.replaceAll('__MainMessage', '_MainMessage');
  content = content.replaceAll('__MainTaskMessage', '_MainTaskMessage');
  content = content.replaceAll('__MainShutdownMessage', '_MainShutdownMessage');

  file.writeAsStringSync(content);
}
