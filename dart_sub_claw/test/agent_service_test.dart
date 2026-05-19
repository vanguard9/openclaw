import 'dart:io';

import 'package:dart_sub_claw/src/agent/cancellation.dart';
import 'package:dart_sub_claw/src/agent/agent_service.dart';
import 'package:dart_sub_claw/src/config/config_store.dart';
import 'package:dart_sub_claw/src/providers/chat_provider.dart';
import 'package:dart_sub_claw/src/sessions/chat_message.dart';
import 'package:dart_sub_claw/src/sessions/session_store.dart';
import 'package:dart_sub_claw/src/tools/tool_runtime.dart';

class EchoProvider implements ChatProvider {
  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return 'echo: ${messages.last.content}';
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    cancellationToken?.throwIfCancelled();
    yield 'echo: ';
    cancellationToken?.throwIfCancelled();
    yield messages.last.content;
  }
}

class WaitingProvider implements ChatProvider {
  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    await cancellationToken?.cancelled;
    cancellationToken?.throwIfCancelled();
    return 'unreachable';
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    yield 'partial';
    await cancellationToken?.cancelled;
    cancellationToken?.throwIfCancelled();
  }
}

class ScriptedProvider implements ChatProvider {
  ScriptedProvider(this.replies);

  final List<String> replies;
  int index = 0;

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return _next();
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    cancellationToken?.throwIfCancelled();
    for (final char in _next().split('')) {
      yield char;
    }
  }

  String _next() {
    if (index >= replies.length) {
      throw StateError('no scripted reply left');
    }
    return replies[index++];
  }
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_claw_test_');
  final service = AgentService(
    configStore: ConfigStore(home: temp),
    sessionStore: SessionStore(home: temp),
    provider: EchoProvider(),
  );

  final result = await service.runTurn(message: 'hello', sessionId: 'test');
  if (result.reply != 'echo: hello') {
    throw StateError('unexpected reply: ${result.reply}');
  }

  final messages = await SessionStore(home: temp).read('test');
  if (messages.length != 2 ||
      messages[0].role != 'user' ||
      messages[1].role != 'assistant') {
    throw StateError('session persistence failed');
  }

  final deltas = <String>[];
  final streamResult = await service.runTurnStreaming(
    message: 'stream',
    sessionId: 'stream-test',
    onDelta: deltas.add,
  );
  if (streamResult.reply != 'echo: stream' || deltas.join() != 'echo: stream') {
    throw StateError('streaming agent turn failed');
  }

  final cancelTemp =
      await Directory.systemTemp.createTemp('dart_sub_claw_cancel_test_');
  final cancelService = AgentService(
    configStore: ConfigStore(home: cancelTemp),
    sessionStore: SessionStore(home: cancelTemp),
    provider: WaitingProvider(),
  );
  final cancellation = CancellationController();
  final deltasBeforeCancel = <String>[];
  final pending = cancelService.runTurnStreaming(
    message: 'cancel me',
    sessionId: 'cancel-test',
    onDelta: deltasBeforeCancel.add,
    cancellationToken: cancellation.token,
  );
  while (deltasBeforeCancel.isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  cancellation.cancel();
  try {
    await pending;
    throw StateError('cancelled turn should throw');
  } on CancelledException {
    final messagesAfterCancel =
        await SessionStore(home: cancelTemp).read('cancel-test');
    if (messagesAfterCancel.length != 1 ||
        messagesAfterCancel.single.role != 'user') {
      throw StateError('cancelled turn should not persist assistant reply');
    }
  }
  await cancelTemp.delete(recursive: true);

  final toolTemp =
      await Directory.systemTemp.createTemp('dart_sub_claw_tool_test_');
  await File('${toolTemp.path}${Platform.pathSeparator}input.txt')
      .writeAsString('tool input');
  final toolProvider = ScriptedProvider([
    '<tool_call>{"tool":"read_file","arguments":{"path":"input.txt"}}</tool_call>',
    'read result included',
  ]);
  final toolService = AgentService(
    configStore: ConfigStore(home: toolTemp),
    sessionStore: SessionStore(home: toolTemp),
    provider: toolProvider,
    toolRuntime: ToolRuntime(root: toolTemp),
  );
  final toolResult = await toolService.runTurn(
    message: 'read input.txt',
    sessionId: 'tool-test',
  );
  if (toolResult.reply != 'read result included' || toolProvider.index != 2) {
    throw StateError('tool loop failed: ${toolResult.reply}');
  }
  final persistedToolMessages =
      await SessionStore(home: toolTemp).read('tool-test');
  if (persistedToolMessages.length != 2 ||
      persistedToolMessages[0].role != 'user' ||
      persistedToolMessages[1].role != 'assistant') {
    throw StateError('tool internals should not be persisted');
  }
  final runtime = ToolRuntime(
    root: toolTemp,
    permissionHandler: (_) async => ToolPermissionDecision.allow,
  );
  final writeResult = await runtime.run(ToolCall(
    tool: 'write_file',
    arguments: {
      'path': 'nested/output.txt',
      'content': 'written',
    },
  ));
  final written = await File(
          '${toolTemp.path}${Platform.pathSeparator}nested${Platform.pathSeparator}output.txt')
      .readAsString();
  if (!writeResult.ok || written != 'written') {
    throw StateError('write_file failed: ${writeResult.output}');
  }
  final escapeResult = await runtime.run(ToolCall(
    tool: 'read_file',
    arguments: {'path': '../outside.txt'},
  ));
  if (escapeResult.ok || !escapeResult.output.contains('escapes tool root')) {
    throw StateError('path escape should be rejected: ${escapeResult.output}');
  }
  final deniedRuntime = ToolRuntime(root: toolTemp);
  final deniedWrite = await deniedRuntime.run(ToolCall(
    tool: 'write_file',
    arguments: {
      'path': 'denied.txt',
      'content': 'denied',
    },
  ));
  if (deniedWrite.ok || deniedWrite.code != 'permission_denied') {
    throw StateError('write_file should require permission');
  }
  final allowedRead = await deniedRuntime.run(ToolCall(
    tool: 'read_file',
    arguments: {'path': 'input.txt'},
  ));
  if (!allowedRead.ok || allowedRead.output != 'tool input') {
    throw StateError('read_file should be allowed by default');
  }
  final mixedCall = deniedRuntime.parseToolCall(
    '我来处理。<tool_call>write_file{"arguments":{"path":"denied.txt","content":"x"},"tool":"write_file"}',
  );
  if (mixedCall == null ||
      mixedCall.tool != 'write_file' ||
      mixedCall.arguments['path'] != 'denied.txt') {
    throw StateError('mixed tool call should be parsed');
  }
  final writableOutside =
      await Directory.systemTemp.createTemp('dart_sub_claw_writable_root_');
  try {
    final absoluteOutput =
        '${writableOutside.path}${Platform.pathSeparator}absolute.txt';
    final writableRuntime = ToolRuntime(
      root: toolTemp,
      writableRoots: [writableOutside],
      permissionHandler: (_) => ToolPermissionDecision.allow,
    );
    final absoluteWrite = await writableRuntime.run(ToolCall(
      tool: 'write_file',
      arguments: {
        'path': absoluteOutput,
        'content': 'absolute',
      },
    ));
    final absoluteWritten = await File(absoluteOutput).readAsString();
    if (!absoluteWrite.ok || absoluteWritten != 'absolute') {
      throw StateError('writable root write failed: ${absoluteWrite.output}');
    }
    final deniedAbsoluteRead = await writableRuntime.run(ToolCall(
      tool: 'read_file',
      arguments: {'path': absoluteOutput},
    ));
    if (deniedAbsoluteRead.ok ||
        !deniedAbsoluteRead.output.contains('escapes tool root')) {
      throw StateError('extra writable roots should not allow safe reads');
    }
  } finally {
    await writableOutside.delete(recursive: true);
  }

  final streamingToolProvider = ScriptedProvider([
    '<tool_call>{"tool":"shell","arguments":{"command":"printf streamed-tool"}}</tool_call>',
    'final after tool',
  ]);
  final streamingToolService = AgentService(
    configStore: ConfigStore(home: toolTemp),
    sessionStore: SessionStore(home: toolTemp),
    provider: streamingToolProvider,
    toolRuntime: ToolRuntime(
      root: toolTemp,
      permissionHandler: (request) async {
        if (request.tool != 'shell' || request.risk != ToolRisk.dangerous) {
          throw StateError('unexpected permission request: ${request.tool}');
        }
        return ToolPermissionDecision.allow;
      },
    ),
  );
  final streamed = <String>[];
  final streamingToolResult = await streamingToolService.runTurnStreaming(
    message: 'use shell',
    sessionId: 'streaming-tool-test',
    onDelta: streamed.add,
  );
  if (streamingToolResult.reply != 'final after tool' ||
      streamed.join() != 'final after tool' ||
      streamed.join().contains('<tool_call>')) {
    throw StateError('streaming tool call leaked or failed: $streamed');
  }
  final deniedShellProvider = ScriptedProvider([
    '<tool_call>{"tool":"shell","arguments":{"command":"printf denied"}} </tool_call>',
    'shell was denied',
  ]);
  final deniedShellService = AgentService(
    configStore: ConfigStore(home: toolTemp),
    sessionStore: SessionStore(home: toolTemp),
    provider: deniedShellProvider,
    toolRuntime: ToolRuntime(root: toolTemp),
  );
  final deniedShellResult = await deniedShellService.runTurn(
    message: 'try shell',
    sessionId: 'denied-shell-tool-test',
  );
  if (deniedShellResult.reply != 'shell was denied') {
    throw StateError('denied shell flow failed: ${deniedShellResult.reply}');
  }
  await toolTemp.delete(recursive: true);

  await temp.delete(recursive: true);
}
