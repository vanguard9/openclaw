import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final expectPath = await _which('expect');
  if (expectPath == null) {
    stderr.writeln('skip: expect is not installed');
    return;
  }

  await _runExpect(
    name: 'exit',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-exit-smoke --history 0
after 1000
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'backspace-del',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-backspace-smoke --history 0
after 1000
send "/statxx\177\177us\r"
expect "notice: env=default"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'backspace-ctrl-h',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-ctrlh-smoke --history 0
after 1000
send "/statxx\b\bus\r"
expect "notice: env=default"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'input-history',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-history-smoke --history 0
after 1000
send "/status\r"
expect "notice: env=default"
send "\033\[A"
expect "you> /status"
send "\033\[B"
expect "you> 输入消息或 /help"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'ctrl-c-clear-then-exit',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-ctrlc-clear-smoke --history 0
after 1000
send "draft"
expect "you> draft"
send "\003"
expect "notice: cleared input; press ctrl+c again to exit"
expect "you> 输入消息或 /help"
send "\003"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'ctrl-c-warn-then-exit',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-ctrlc-warn-smoke --history 0
after 1000
send "\003"
expect "notice: press ctrl+c again to exit"
send "\003"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'mouse-wheel-is-ignored',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-mouse-smoke --history 0
after 1000
send "hello"
expect "you> hello"
send "\033\[<64;10;10M"
after 500
send "\033\[<65;10;10M"
after 500
send "\033\[Mabc"
after 500
send "\b\b\b\b\b"
expect "you> 输入消息或 /help"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'scroll-history',
    setup: (home) async {
      final sessionsDir =
          Directory('${home.path}${Platform.pathSeparator}sessions');
      await sessionsDir.create(recursive: true);
      final file = File(
          '${sessionsDir.path}${Platform.pathSeparator}tui-scroll-smoke.jsonl');
      final lines = <String>[];
      for (var i = 0; i < 30; i++) {
        lines.add(jsonEncode({
          'role': i.isEven ? 'user' : 'assistant',
          'content': 'scroll line $i',
          'createdAt': DateTime.utc(2026, 1, 1, 0, 0, i).toIso8601String(),
        }));
      }
      await file.writeAsString('${lines.join('\n')}\n');
    },
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-scroll-smoke --history 40
after 1000
send "\033\[5~"
expect "scroll:"
send "\033\[6~"
after 500
send "\033\[<64;10;10M"
expect "scroll:"
send "\033\[<65;10;10M"
after 500
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  final slowServer = await _startSlowSseServer();
  try {
    await _runExpect(
      name: 'esc-cancel',
      setup: (home) => _writeSlowProviderConfig(home, slowServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-esc-cancel-smoke --history 0
after 1000
send "slow\r"
expect "assistant> partial"
send "\033"
expect "notice: run cancelled"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );

    await _runExpect(
      name: 'slash-cancel',
      setup: (home) => _writeSlowProviderConfig(home, slowServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-slash-cancel-smoke --history 0
after 1000
send "slow\r"
expect "assistant> partial"
send "/cancel\r"
expect "notice: run cancelled"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );
  } finally {
    await slowServer.close(force: true);
  }

  final toolServer = await _startToolSseServer();
  try {
    await _runExpect(
      name: 'tool-permission-allow',
      setup: (home) => _writeProviderConfig(home, toolServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-tool-allow-smoke --history 0
after 1000
send "use shell\r"
expect "confirm: allow dangerous tool shell?"
send "y"
expect "assistant> tool allowed final"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );

    await _runExpect(
      name: 'tool-permission-deny',
      setup: (home) => _writeProviderConfig(home, toolServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-tool-deny-smoke --history 0
after 1000
send "use shell\r"
expect "confirm: allow dangerous tool shell?"
send "n"
expect "assistant> tool denied final"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );

    await _runExpect(
      name: 'tool-permission-remember-session',
      setup: (home) => _writeProviderConfig(home, toolServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-tool-remember-smoke --history 0
after 1000
send "use shell\r"
expect "confirm: allow dangerous tool shell?"
send "a"
expect "assistant> tool allowed final"
after 500
send "use shell again\r"
expect "assistant> tool allowed final"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );
  } finally {
    await toolServer.close(force: true);
  }
}

Future<String?> _which(String executable) async {
  final result = await Process.run('which', [executable]);
  if (result.exitCode != 0) {
    return null;
  }
  return (result.stdout as String).trim();
}

Future<void> _runExpect({
  required String name,
  required String script,
  Future<void> Function(Directory home)? setup,
}) async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_claw_tui_$name');
  try {
    await setup?.call(temp);
    final result = await Process.run(
      'expect',
      ['-c', script],
      workingDirectory: Directory.current.path,
      environment: {
        'DART_SUB_CLAW_HOME': temp.path,
      },
    );
    if (result.exitCode != 0) {
      stderr.writeln(result.stdout);
      stderr.writeln(result.stderr);
      throw StateError('TUI smoke test failed: $name');
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<HttpServer> _startSlowSseServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    try {
      if (request.uri.path != '/chat/completions') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      response.write(
        'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
      );
      await response.flush();
      await Future<void>.delayed(const Duration(seconds: 5));
      response.write('data: [DONE]\n\n');
      await response.close();
    } catch (_) {
      await response.close().catchError((_) {});
    }
  });
  return server;
}

Future<HttpServer> _startToolSseServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    try {
      if (request.uri.path != '/chat/completions') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final isToolResult = body.contains('Tool result:');
      final content = isToolResult
          ? body.contains('permission_denied')
              ? 'tool denied final'
              : 'tool allowed final'
          : '我来执行。<tool_call>shell{"arguments":{"command":"printf tui-permission"},"tool":"shell"}';
      response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      response.write(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': content},
                },
              ],
            })}\n\n',
      );
      response.write('data: [DONE]\n\n');
      await response.close();
    } catch (_) {
      await response.close().catchError((_) {});
    }
  });
  return server;
}

Future<void> _writeSlowProviderConfig(Directory home, int port) async {
  await _writeProviderConfig(home, port);
}

Future<void> _writeProviderConfig(Directory home, int port) async {
  await home.create(recursive: true);
  final file = File('${home.path}${Platform.pathSeparator}config.json');
  await file.writeAsString(
    '${jsonEncode({
          'provider': {
            'kind': 'openai-compatible',
            'baseUrl': 'http://127.0.0.1:$port',
            'model': 'slow-test',
            'apiKey': 'test-key',
            'apiKeyEnv': 'DART_SUB_CLAW_TEST_API_KEY',
          },
          'gateway': {
            'host': '127.0.0.1',
            'port': 18987,
          },
        })}\n',
  );
}
