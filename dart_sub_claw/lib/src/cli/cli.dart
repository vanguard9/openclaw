import 'dart:convert';
import 'dart:io';

import '../agent/agent_service.dart';
import '../config/config_store.dart';
import '../gateway/gateway_server.dart';

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

final IOSink ioStdout = stdout;
final IOSink ioStderr = stderr;

Future<int> _runAgent(List<String> args, IOSink out, IOSink err) async {
  final message = _optionValue(args, '--message') ?? _optionValue(args, '-m');
  final sessionId = _optionValue(args, '--session') ?? 'default';
  if (message == null || message.trim().isEmpty) {
    err.writeln('agent requires --message <text>');
    return 64;
  }
  final result =
      await AgentService().runTurn(message: message, sessionId: sessionId);
  out.writeln(result.reply);
  return 0;
}

Future<int> _runConfig(List<String> args, IOSink out) async {
  final store = ConfigStore();
  if (args.isEmpty || args.first == 'list') {
    final config = await store.ensureExists();
    const encoder = JsonEncoder.withIndent('  ');
    out.writeln(encoder.convert(redactConfigForDisplay(config)));
    return 0;
  }
  if (args.first == 'get' && args.length == 2) {
    final value = await store.getValue(args[1]);
    out.writeln(value ?? '');
    return 0;
  }
  if (args.first == 'set' && args.length >= 3) {
    final value = args.skip(2).join(' ');
    await store.setValue(args[1], value);
    out.writeln('set ${args[1]}');
    return 0;
  }
  out.writeln('usage: dartsub config [list|get <key>|set <key> <value>]');
  return 64;
}

Future<int> _runGateway(List<String> args, IOSink out) async {
  if (args.isNotEmpty && args.first != 'run') {
    out.writeln('usage: dartsub gateway run [--host <host>] [--port <port>]');
    return 64;
  }
  final rest = args.isNotEmpty ? args.skip(1).toList() : <String>[];
  final host = _optionValue(rest, '--host');
  final portRaw = _optionValue(rest, '--port');
  final port = portRaw == null ? null : int.tryParse(portRaw);
  if (portRaw != null && port == null) {
    out.writeln('--port must be a number');
    return 64;
  }

  final server = GatewayServer();
  final uri = await server.start(host: host, port: port);
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

void _printHelp(IOSink out) {
  out.writeln('''
dartsub

Commands:
  agent --message <text> [--session <id>]      Run one agent turn
  gateway run [--host <host>] [--port <port>] Start local HTTP/WebSocket gateway
  config list                                  Show config
  config get <key>                             Read config value
  config set <key> <value>                     Write config value

Useful config keys:
  provider.baseUrl
  provider.model
  provider.apiKey
  provider.apiKeyEnv
  gateway.host
  gateway.port
''');
}
