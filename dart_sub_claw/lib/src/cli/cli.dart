import 'dart:convert';
import 'dart:io';

import '../agent/agent_service.dart';
import '../config/config_store.dart';
import '../doctor/doctor.dart';
import '../gateway/gateway_server.dart';
import '../tui/repl_tui.dart';

Future<int> runCli(
  List<String> args, {
  IOSink? stdout,
  IOSink? stderr,
}) async {
  final out = stdout ?? ioStdout;
  final err = stderr ?? ioStderr;
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _printHelp(out);
    return 0;
  }

  try {
    switch (args.first) {
      case 'agent':
        return await _runAgent(args.skip(1).toList(), out, err);
      case 'config':
        return await _runConfig(args.skip(1).toList(), out);
      case 'gateway':
        return await _runGateway(args.skip(1).toList(), out);
      case 'tui':
        return await _runTui(args.skip(1).toList(), out);
      case 'doctor':
        return await _runDoctor(args.skip(1).toList(), out);
      case 'help':
        _printHelp(out);
        return 0;
      default:
        err.writeln('Unknown command: ${args.first}');
        _printHelp(err);
        return 64;
    }
  } catch (error) {
    err.writeln('error: $error');
    return 1;
  }
}

Future<int> _runDoctor(List<String> args, IOSink out) async {
  final environment = _optionValue(args, '--env') ??
      _optionValue(args, '-e') ??
      Platform.environment['DARTSUB_ENV'];
  final report = await DartSubDoctor().run(
    DoctorOptions(
      environment: environment,
      skipModel: args.contains('--skip-model'),
    ),
  );
  report.writeTo(out);
  return report.hasFailures ? 1 : 0;
}

Future<int> _runTui(List<String> args, IOSink out) async {
  final environment = _optionValue(args, '--env') ??
      _optionValue(args, '-e') ??
      Platform.environment['DARTSUB_ENV'];
  final sessionId = _optionValue(args, '--session') ?? 'default';
  final historyRaw = _optionValue(args, '--history');
  final historyLimit = historyRaw == null ? 12 : int.tryParse(historyRaw);
  if (historyLimit == null || historyLimit < 0) {
    out.writeln('--history must be a non-negative number');
    return 64;
  }
  return ReplTui().run(
    sessionId: sessionId,
    environment: environment,
    historyLimit: historyLimit,
  );
}

final IOSink ioStdout = stdout;
final IOSink ioStderr = stderr;

Future<int> _runAgent(List<String> args, IOSink out, IOSink err) async {
  final environment = _optionValue(args, '--env') ??
      _optionValue(args, '-e') ??
      Platform.environment['DARTSUB_ENV'];
  final message = _optionValue(args, '--message') ?? _optionValue(args, '-m');
  final sessionId = _optionValue(args, '--session') ?? 'default';
  if (message == null || message.trim().isEmpty) {
    err.writeln('agent requires --message <text>');
    return 64;
  }
  final result = await AgentService().runTurn(
      message: message, sessionId: sessionId, environment: environment);
  out.writeln(result.reply);
  return 0;
}

Future<int> _runConfig(List<String> args, IOSink out) async {
  final environment = _optionValue(args, '--env') ?? _optionValue(args, '-e');
  final commandArgs = _withoutOption(_withoutOption(args, '--env'), '-e');
  final store = ConfigStore();
  if (commandArgs.isEmpty || commandArgs.first == 'list') {
    final config = await store.ensureExists();
    const encoder = JsonEncoder.withIndent('  ');
    out.writeln(encoder.convert(redactConfigForDisplay(config)));
    return 0;
  }
  if (commandArgs.first == 'get' && commandArgs.length == 2) {
    final value =
        await store.getValue(commandArgs[1], environment: environment);
    out.writeln(value ?? '');
    return 0;
  }
  if (commandArgs.first == 'set' && commandArgs.length >= 3) {
    final value = commandArgs.skip(2).join(' ');
    await store.setValue(commandArgs[1], value, environment: environment);
    out.writeln('set ${commandArgs[1]}');
    return 0;
  }
  out.writeln(
      'usage: dartsub config [--env <name>] [list|get <key>|set <key> <value>]');
  return 64;
}

Future<int> _runGateway(List<String> args, IOSink out) async {
  final environment = _optionValue(args, '--env') ??
      _optionValue(args, '-e') ??
      Platform.environment['DARTSUB_ENV'];
  final commandArgs = _withoutOption(_withoutOption(args, '--env'), '-e');
  if (commandArgs.isNotEmpty && commandArgs.first != 'run') {
    out.writeln(
        'usage: dartsub gateway run [--env <name>] [--host <host>] [--port <port>]');
    return 64;
  }
  final rest =
      commandArgs.isNotEmpty ? commandArgs.skip(1).toList() : <String>[];
  final host = _optionValue(rest, '--host');
  final portRaw = _optionValue(rest, '--port');
  final port = portRaw == null ? null : int.tryParse(portRaw);
  if (portRaw != null && port == null) {
    out.writeln('--port must be a number');
    return 64;
  }

  final server = GatewayServer(environment: environment);
  final uri =
      await server.start(host: host, port: port, environment: environment);
  out.writeln('dartsub gateway listening on $uri');
  await ProcessSignal.sigint.watch().first;
  await server.close();
  return 0;
}

String? _optionValue(List<String> args, String name) {
  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    if (arg == name && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$name=')) {
      return arg.substring(name.length + 1);
    }
  }
  return null;
}

List<String> _withoutOption(List<String> args, String name) {
  final result = <String>[];
  for (var i = 0; i < args.length; i += 1) {
    final arg = args[i];
    if (arg == name) {
      i += 1;
      continue;
    }
    if (arg.startsWith('$name=')) {
      continue;
    }
    result.add(arg);
  }
  return result;
}

void _printHelp(IOSink out) {
  out.writeln('''
dartsub

Commands:
  agent [--env <name>] --message <text> [--session <id>] Run one agent turn
  gateway run [--env <name>] [--host <host>] [--port <port>]
                                                       Start local HTTP/WebSocket gateway
  tui [--env <name>] [--session <id>] [--history <n>]  Start terminal chat
  doctor [--env <name>] [--skip-model]                 Check config and runtime health
  config [--env <name>] list                          Show config
  config [--env <name>] get <key>                     Read config value
  config [--env <name>] set <key> <value>             Write config value

Useful config keys:
  provider.baseUrl
  provider.model
  provider.apiKey
  provider.apiKeyEnv
  gateway.host
  gateway.port
''');
}
