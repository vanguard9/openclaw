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
