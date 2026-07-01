// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Runs a [Process].
///
/// If [logger] is provided, stream stdout and stderr to it.
///
/// If [captureOutput], captures stdout and stderr.
Future<RunProcessResult> runProcess({
  required Uri executable,
  required Logger? logger,
  List<String> arguments = const [],
  Uri? workingDirectory,
  Map<String, String>? environment,
  bool captureOutput = true,
  int expectedExitCode = 0,
  bool throwOnUnexpectedExitCode = false,
}) async {
  // Merge with current process env so Windows-specific vars (e.g. LOCALAPPDATA)
  // are available to tools like ccache. Explicit overrides in [environment] win.
  final mergedEnvironment = <String, String>{...Platform.environment, ...?environment};
  if (Platform.isWindows) {
    final userProfile = mergedEnvironment['USERPROFILE'];
    mergedEnvironment.putIfAbsent(
      'LOCALAPPDATA',
      () => userProfile == null ? '' : '$userProfile\\AppData\\Local',
    );
    mergedEnvironment.putIfAbsent(
      'APPDATA',
      () => userProfile == null ? '' : '$userProfile\\AppData\\Roaming',
    );
    // If we couldn't infer, remove empty placeholders.
    if (mergedEnvironment['LOCALAPPDATA']?.isEmpty ?? false) {
      mergedEnvironment.remove('LOCALAPPDATA');
    }
    if (mergedEnvironment['APPDATA']?.isEmpty ?? false) {
      mergedEnvironment.remove('APPDATA');
    }
  }
  final printWorkingDir = workingDirectory != null && workingDirectory != Directory.current.uri;
  final commandString = [
    if (printWorkingDir) '(cd ${workingDirectory.toFilePath()};',
    ...?environment?.entries.map((entry) => '${entry.key}=${entry.value}'),
    executable.toFilePath(),
    ...arguments.map((a) => a.contains(' ') ? "'$a'" : a),
    if (printWorkingDir) ')',
  ].join(' ');
  logger?.info('Running `$commandString`.');

  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final process = await Process.start(
    executable.toFilePath(),
    arguments,
    workingDirectory: workingDirectory?.toFilePath(),
    environment: mergedEnvironment,
    runInShell: false,
  );

  final stdoutSub = process.stdout.listen((List<int> data) {
    try {
      final decodedData = _decodePreferUtf8(data);
      logger?.fine(decodedData);
      if (captureOutput) {
        stdoutBuffer.write(decodedData);
      }
    } catch (e) {
      logger?.warning('Failed to decode stdout: $e');
      stdoutBuffer.write('Failed to decode stdout: $e');
    }
  });
  final stderrSub = process.stderr.listen((List<int> data) {
    try {
      final decodedData = _decodePreferUtf8(data);
      logger?.severe(decodedData);
      if (captureOutput) {
        stderrBuffer.write(decodedData);
      }
    } catch (e) {
      logger?.severe('Failed to decode stderr: $e');
      stderrBuffer.write('Failed to decode stderr: $e');
    }
  });

  final (exitCode, _, _) = await (
    process.exitCode,
    stdoutSub.asFuture<void>(),
    stderrSub.asFuture<void>(),
  ).wait;

  await stdoutSub.cancel();
  await stderrSub.cancel();
  final result = RunProcessResult(
    pid: process.pid,
    command: commandString,
    exitCode: exitCode,
    stdout: stdoutBuffer.toString(),
    stderr: stderrBuffer.toString(),
  );
  if (throwOnUnexpectedExitCode && expectedExitCode != exitCode) {
    throw ProcessException(
      executable.toFilePath(),
      arguments,
      "Full command string: '$commandString'.\n"
      "Exit code: '$exitCode'.\n"
      'For the output of the process check the logger output.',
    );
  }
  return result;
}

/// Process.runSync
RunProcessResult runProcessSync({
  required String executable,
  required Logger? logger,
  List<String> arguments = const [],
  Uri? workingDirectory,
  Map<String, String>? environment,
  bool captureOutput = true,
  int expectedExitCode = 0,
  bool throwOnUnexpectedExitCode = false,
}) {
  final mergedEnvironment = <String, String>{...Platform.environment, ...?environment};
  if (Platform.isWindows) {
    final userProfile = mergedEnvironment['USERPROFILE'];
    mergedEnvironment.putIfAbsent(
      'LOCALAPPDATA',
      () => userProfile == null ? '' : '$userProfile\\AppData\\Local',
    );
    mergedEnvironment.putIfAbsent(
      'APPDATA',
      () => userProfile == null ? '' : '$userProfile\\AppData\\Roaming',
    );
    if (mergedEnvironment['LOCALAPPDATA']?.isEmpty ?? false) {
      mergedEnvironment.remove('LOCALAPPDATA');
    }
    if (mergedEnvironment['APPDATA']?.isEmpty ?? false) {
      mergedEnvironment.remove('APPDATA');
    }
  }
  final printWorkingDir = workingDirectory != null && workingDirectory != Directory.current.uri;
  final commandString = [
    if (printWorkingDir) '(cd ${workingDirectory.toFilePath()};',
    ...?environment?.entries.map((entry) => '${entry.key}=${entry.value}'),
    executable,
    ...arguments.map((a) => a.contains(' ') ? "'$a'" : a),
    if (printWorkingDir) ')',
  ].join(' ');
  logger?.info('Running `$commandString`.');

  final result = Process.runSync(
    executable,
    arguments,
    workingDirectory: workingDirectory?.toFilePath(),
    environment: mergedEnvironment,
    runInShell: false,
  );
  final runResult = RunProcessResult(
    pid: result.pid,
    command: commandString,
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  );

  if (captureOutput) {
    if (result.exitCode == expectedExitCode) {
      logger?.info(result.stdout);
    } else {
      logger?.severe(result.stdout);
    }
  }

  if (throwOnUnexpectedExitCode && expectedExitCode != exitCode) {
    throw ProcessException(
      executable,
      arguments,
      "Full command string: '$commandString'.\n"
      "Exit code: '$exitCode'.\n"
      'For the output of the process check the logger output.',
    );
  }
  return runResult;
}

/// Drop in replacement of [ProcessResult].
class RunProcessResult {
  final int pid;

  final String command;

  final int exitCode;

  final String stderr;

  final String stdout;

  RunProcessResult({
    required this.pid,
    required this.command,
    required this.exitCode,
    required this.stderr,
    required this.stdout,
  });

  @override
  String toString() =>
      '''command: $command
exitCode: $exitCode
stdout: $stdout
stderr: $stderr''';
}

String _decodePreferUtf8(List<int> data) {
  try {
    return utf8.decode(data);
  } catch (_) {
    return systemEncoding.decode(data);
  }
}
