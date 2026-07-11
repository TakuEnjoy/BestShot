import 'dart:io';

void main() {
  final file = File('lib/src/services/analysis/analyzer_isolate.dart');
  var content = file.readAsStringSync();

  // Add classes to the bottom
  content += '''

sealed class WorkerMessage {}
class WorkerInitMessage extends WorkerMessage {
  WorkerInitMessage({required this.workerId, required this.sendPort});
  final int workerId;
  final SendPort sendPort;
}
class WorkerResultMessage extends WorkerMessage {
  WorkerResultMessage({required this.workerId, required this.output});
  final int workerId;
  final AnalyzeOutput output;
}
class WorkerDoneMessage extends WorkerMessage {
  WorkerDoneMessage({required this.workerId});
  final int workerId;
}

sealed class MainMessage {}
class MainTaskMessage extends MainMessage {
  MainTaskMessage({required this.input});
  final _TransferableInput input;
}
class MainShutdownMessage extends MainMessage {}
''';

  // Replace map sends
  content = content.replaceAll(
    "workerSendPort.send({'type': 'task', 'input': transferable});",
    "workerSendPort.send(MainTaskMessage(input: transferable));"
  );
  content = content.replaceAll(
    "workerSendPort.send({'type': 'shutdown'});",
    "workerSendPort.send(MainShutdownMessage());"
  );
  
  content = content.replaceAll(
    "if (message is Map) {",
    "if (message is WorkerMessage) {"
  );
  content = content.replaceAll(
    "final type = message['type'];",
    ""
  );
  content = content.replaceAll(
    "final workerId = message['workerId'] as int;",
    ""
  );

  content = content.replaceAll(
    "if (type == 'init') {",
    "if (message is WorkerInitMessage) {\n          final workerId = message.workerId;"
  );
  content = content.replaceAll(
    "final sp = message['sendPort'] as SendPort;",
    "final sp = message.sendPort;"
  );
  content = content.replaceAll(
    "} else if (type == 'result') {",
    "} else if (message is WorkerResultMessage) {\n          final workerId = message.workerId;\n          final out = message.output;"
  );

  content = content.replaceAll(
    "AnalyzeOutput(",
    "AnalyzeOutput("
  );

  // Result parsing
  content = content.replaceFirst(
'''          results.add(
            AnalyzeOutput(
              key: message['key'] as String,
              pHashHex: message['pHashHex'] as String,
              sharpness: (message['sharpness'] as num).toDouble(),
              exposureScore: (message['exposureScore'] as num).toDouble(),
              orbRows: (message['orbRows'] as num).toInt(),
              orbCols: (message['orbCols'] as num).toInt(),
              orbBytes: message['orbBytes'] as Uint8List,
              histogram: message['histogram'] as Uint8List,
              hueHistogram: message['hueHistogram'] as Float32List?,
              hasFace: (message['hasFace'] as bool?) ?? false,
              faceX: (message['faceX'] as num?)?.toInt() ?? 0,
              faceY: (message['faceY'] as num?)?.toInt() ?? 0,
              faceW: (message['faceW'] as num?)?.toInt() ?? 0,
              faceH: (message['faceH'] as num?)?.toInt() ?? 0,
              faceSharpness:
                  (message['faceSharpness'] as num?)?.toDouble() ?? 0,
              eyeOpenAvg: (message['eyeOpenAvg'] as num?)?.toDouble() ?? -1,
              eyesClosed: (message['eyesClosed'] as bool?) ?? false,
              bothEyesDetected: (message['bothEyesDetected'] as bool?) ?? false,
              eyeSharpness: (message['eyeSharpness'] as num?)?.toDouble() ?? -1,
              debugGridSharps: (message['debugGridSharps'] as List?)
                  ?.map((e) => (e as num).toDouble())
                  .toList(),
            ),
          );''',
'''          results.add(out);'''
  );

  content = content.replaceAll(
    "} else if (type == 'done') {",
    "} else if (message is WorkerDoneMessage) {"
  );

  // Worker side
  content = content.replaceFirst(
'''    message.mainSendPort.send({
      'type': 'init',
      'workerId': message.workerId,
      'sendPort': workerReceivePort.sendPort,
    });''',
'''    message.mainSendPort.send(WorkerInitMessage(
      workerId: message.workerId,
      sendPort: workerReceivePort.sendPort,
    ));'''
  );

  content = content.replaceAll(
    "await for (final msg in workerReceivePort) {",
    "await for (final msg in workerReceivePort) {"
  );

  content = content.replaceAll(
'''        if (msg is Map) {
          final type = msg['type'];
          if (type == 'shutdown') {
            break;
          } else if (type == 'task') {
            final input = msg['input'] as _TransferableInput;''',
'''        if (msg is MainMessage) {
          if (msg is MainShutdownMessage) {
            break;
          } else if (msg is MainTaskMessage) {
            final input = msg.input;'''
  );

  content = content.replaceFirst(
'''            message.mainSendPort.send({
              'type': 'result',
              'workerId': message.workerId,
              'key': out.key,
              'pHashHex': out.pHashHex,
              'sharpness': out.sharpness,
              'exposureScore': out.exposureScore,
              'orbRows': out.orbRows,
              'orbCols': out.orbCols,
              'orbBytes': out.orbBytes,
              'histogram': out.histogram,
              'hueHistogram': out.hueHistogram,
              'hasFace': out.hasFace,
              'faceX': out.faceX,
              'faceY': out.faceY,
              'faceW': out.faceW,
              'faceH': out.faceH,
              'faceSharpness': out.faceSharpness,
              'eyeOpenAvg': out.eyeOpenAvg,
              'eyesClosed': out.eyesClosed,
              'bothEyesDetected': out.bothEyesDetected,
              'eyeSharpness': out.eyeSharpness,
              'debugGridSharps': out.debugGridSharps,
            });''',
'''            message.mainSendPort.send(WorkerResultMessage(
              workerId: message.workerId,
              output: out,
            ));'''
  );

  content = content.replaceAll(
    "message.mainSendPort.send({'type': 'done', 'workerId': message.workerId});",
    "message.mainSendPort.send(WorkerDoneMessage(workerId: message.workerId));"
  );

  file.writeAsStringSync(content);
}
