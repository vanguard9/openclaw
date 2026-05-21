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
expect "notice: status:"
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
expect "notice: status:"
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
expect "notice: status:"
expect "provider: openai-compatible"
expect "gateway: 127.0.0.1:18987"
send "\033\[A"
expect "you> /status"
send "\033\[B"
expect "you> "
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
expect "you> "
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
    name: 'ctrl-d-exits-only-on-empty-input',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-ctrld-smoke --history 0
after 1000
send "draft"
expect "you> draft"
send "\004"
expect "you> draft"
send "\003"
expect "notice: cleared input; press ctrl+c again to exit"
send "\004"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'ctrl-t-toggle-thinking-display',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-ctrlt-smoke --history 0
after 1000
send "\024"
expect "notice: thinking display off"
expect "status=idle | thinking=off"
send "\024"
expect "notice: thinking display on"
expect "status=idle | thinking=on"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'lang-switch-zh-cn',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-lang-smoke --history 0
after 1000
expect "lang=en-US (English)"
send "/lang zh-CN\r"
expect "提示: 语言已切换到 zh-CN"
expect "lang=zh-CN (中文)"
send "/help\r"
expect "TUI 帮助"
expect "/status  显示状态"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'slash-command-suggestions',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-slash-suggest-smoke --history 0
after 1000
send "/"
expect "Command suggestions"
expect "/help"
send "h"
expect "/help  show help"
send "\t"
expect "you> /help"
send "\r"
expect "TUI help"
expect "Ctrl-O expands tool details"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'slash-lang-choice-panel',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-lang-panel-smoke --history 0
after 1000
send "/lang "
expect "Command suggestions"
expect "auto"
expect "zh-CN"
send "\033\[B"
send "\r"
expect "提示: 语言已切换到 zh-CN"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'slash-env-choice-panel',
    setup: _writeEnvSuggestionConfig,
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-env-panel-smoke --history 0
after 1000
send "/env d"
expect "Command suggestions"
expect "dev  switch environment"
send "\r"
expect "notice: environment switched to dev"
expect "env=dev"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'slash-session-choice-panel',
    setup: _writeSessionSuggestion,
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --session tui-session-panel-current --history 0
after 1000
send "/session tui-session-panel-t"
expect "Command suggestions"
expect "tui-session-panel-target"
send "\r"
expect "notice: session switched to tui-session-panel-target"
expect "session=tui-session-panel-target"
send "/exit\r"
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
send "\b\b\b\b\b"
expect "you> "
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
  );

  await _runExpect(
    name: 'mouse-click-keeps-empty-input',
    script: r'''
set timeout 8
spawn dart run bin/dart_sub_claw.dart tui --mouse --session tui-mouse-click-smoke --history 0
after 1000
expect "you> "
send "\033\[<0;10;10M"
expect "you> "
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
      setup: (home) => _writeProviderConfig(
        home,
        toolServer.port,
        allowShellForSession: 'tui-tool-allow-smoke',
      ),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-tool-allow-smoke --history 0
after 1000
send "use shell\r"
expect "status=permission required: shell"
expect "Permission required"
expect "AI is paused and waiting for your permission."
expect "arguments: hidden, press Ctrl-O for details"
expect "choice> y allow once"
send "\017"
expect "printf tui-permission"
send "y"
expect "tool> shell completed"
expect "output>"
expect "tui-permission"
expect "assistant> tool allowed final"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );

    await _runExpect(
      name: 'tool-failure-details',
      setup: (home) => _writeProviderConfig(home, toolServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --session tui-tool-failure-smoke --history 0
after 1000
send "fail shell\r"
expect "Permission required"
send "y"
expect "tool> shell failed exit=7"
send "\017"
expect "arguments>"
expect "exit 7"
expect "output>"
expect "stdout:"
expect "tool-line-two"
expect "stderr:"
expect "tool-error"
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
expect "Permission required"
expect "choice> y allow once"
send "n"
expect "tool> shell denied"
expect "assistant> tool denied final"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );

    await _runExpect(
      name: 'tool-permission-zh-cn',
      setup: (home) => _writeProviderConfig(home, toolServer.port),
      script: r'''
set timeout 12
spawn dart run bin/dart_sub_claw.dart tui --locale zh-CN --session tui-tool-zh-smoke --history 0
after 1000
send "use shell\r"
expect "状态=需要授权: shell"
expect "需要用户授权"
expect "AI 已暂停，正在等待你的授权决定。"
expect "choice> y 允许一次"
send "n"
expect "tool> shell 被拒绝"
expect "assistant> tool denied final"
send "/exit\r"
expect eof
catch wait result
set code [lindex $result 3]
if {$code != 0} { exit $code }
''',
    );

    await _runExpect(
      name: 'tool-permission-tight-terminal',
      setup: (home) => _writeProviderConfig(home, toolServer.port),
      script: r'''
set timeout 12
spawn sh -lc "stty rows 10 columns 50; exec dart run bin/dart_sub_claw.dart tui --session tui-tool-tight-smoke --history 0"
after 1000
send "use shell\r"
expect "status=permission: shell"
expect "Permission required"
expect "choice> y allow"
send "n"
expect "tool> shell denied"
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
expect "Permission required"
expect "choice> y allow once"
send "a"
expect "tool> shell completed"
expect "assistant> tool allowed final"
after 500
send "use shell again\r"
expect "tool> shell completed"
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
        'DARTSUB_TUI_LOCALE': 'en-US',
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
      final failingShell = body.contains('fail shell');
      final content = isToolResult
          ? body.contains('permission_denied')
              ? 'tool denied final'
              : 'tool allowed final'
          : failingShell
              ? '我来执行。<tool_call>shell{"arguments":{"command":"printf tool-line-one; echo; printf tool-line-two; printf tool-error >&2; exit 7"},"tool":"shell"}'
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

Future<void> _writeEnvSuggestionConfig(Directory home) async {
  await home.create(recursive: true);
  final file = File('${home.path}${Platform.pathSeparator}config.json');
  await file.writeAsString(
    '${jsonEncode({
          'environments': {
            'dev': {
              'provider': {
                'model': 'dev-model',
              },
            },
          },
        })}\n',
  );
}

Future<void> _writeSessionSuggestion(Directory home) async {
  final sessionsDir =
      Directory('${home.path}${Platform.pathSeparator}sessions');
  await sessionsDir.create(recursive: true);
  final file = File(
    '${sessionsDir.path}${Platform.pathSeparator}tui-session-panel-target.jsonl',
  );
  await file.writeAsString(
    '${jsonEncode({
          'role': 'assistant',
          'content': 'session panel target',
          'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        })}\n',
  );
}

Future<void> _writeProviderConfig(
  Directory home,
  int port, {
  String? allowShellForSession,
}) async {
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
          if (allowShellForSession != null)
            'toolPolicy': {
              'sessions': {
                allowShellForSession: {
                  'shell': 'allow',
                },
              },
            },
        })}\n',
  );
}
