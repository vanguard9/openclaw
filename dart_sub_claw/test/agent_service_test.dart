import 'dart:io';

import 'package:dart_sub_claw/src/agent/cancellation.dart';
import 'package:dart_sub_claw/src/agent/agent_service.dart';
import 'package:dart_sub_claw/src/config/app_config.dart';
import 'package:dart_sub_claw/src/config/config_store.dart';
import 'package:dart_sub_claw/src/providers/chat_provider.dart';
import 'package:dart_sub_claw/src/sessions/chat_message.dart';
import 'package:dart_sub_claw/src/sessions/session_store.dart';
import 'package:dart_sub_claw/src/tools/tool_policy.dart';
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

class MetadataProvider implements ChatProvider, DetailedChatProvider {
  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    return (await completeDetailed(
      messages: messages,
      cancellationToken: cancellationToken,
    ))
        .content;
  }

  @override
  Future<ChatCompletionResult> completeDetailed({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    return const ChatCompletionResult(
      content: 'metadata reply',
      metadata: ChatCompletionMetadata(
        model: 'metadata-model',
        finishReason: 'stop',
        usage: {'total_tokens': 9},
      ),
    );
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) {
    return completeStreamDetailed(
      messages: messages,
      cancellationToken: cancellationToken,
    ).map((event) => event.delta).where((delta) => delta.isNotEmpty);
  }

  @override
  Stream<ChatStreamEvent> completeStreamDetailed({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    yield const ChatStreamEvent(
      delta: 'metadata ',
      metadata: ChatCompletionMetadata(model: 'stream-model'),
    );
    yield const ChatStreamEvent(
      delta: 'stream',
      metadata: ChatCompletionMetadata(
        finishReason: 'stop',
        usage: {'total_tokens': 11},
      ),
    );
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

  final metadataService = AgentService(
    configStore: ConfigStore(home: temp),
    sessionStore: SessionStore(home: temp),
    provider: MetadataProvider(),
  );
  final metadataResult = await metadataService.runTurn(
    message: 'metadata',
    sessionId: 'metadata-test',
  );
  if (metadataResult.reply != 'metadata reply' ||
      metadataResult.metadata.model != 'metadata-model' ||
      metadataResult.metadata.finishReason != 'stop' ||
      metadataResult.metadata.usage['total_tokens'] != 9) {
    throw StateError('metadata result was not preserved');
  }
  final metadataDeltas = <String>[];
  final metadataStreamResult = await metadataService.runTurnStreaming(
    message: 'metadata stream',
    sessionId: 'metadata-stream-test',
    onDelta: metadataDeltas.add,
  );
  if (metadataStreamResult.reply != 'metadata stream' ||
      metadataDeltas.join() != 'metadata stream' ||
      metadataStreamResult.metadata.model != 'stream-model' ||
      metadataStreamResult.metadata.finishReason != 'stop' ||
      metadataStreamResult.metadata.usage['total_tokens'] != 11) {
    throw StateError('stream metadata result was not preserved');
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
  final policyDeniedRead = await deniedRuntime.run(
    ToolCall(
      tool: 'read_file',
      arguments: {'path': 'input.txt'},
    ),
    policy: ToolPermissionPolicy(
      tools: {'read_file': ToolPolicyDecision.deny},
    ),
  );
  if (policyDeniedRead.ok || policyDeniedRead.code != 'permission_denied') {
    throw StateError('tool policy should be able to deny safe reads');
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

  final policyTemp =
      await Directory.systemTemp.createTemp('dart_sub_claw_policy_test_');
  final policyConfigStore = ConfigStore(home: policyTemp);
  final policySessionStore = SessionStore(home: policyTemp);
  await policyConfigStore.save(AppConfig(
    provider: ProviderConfig(apiKey: 'test-key'),
    toolPolicy: ToolPolicyConfig(
      tools: {'shell': ToolPolicyDecision.deny},
      sessions: {
        'remembered': {'shell': ToolPolicyDecision.allow},
      },
    ),
  ));
  final policyProvider = ScriptedProvider([
    '<tool_call>{"tool":"shell","arguments":{"command":"printf allowed-by-session"}} </tool_call>',
    'policy allowed final',
  ]);
  final policyService = AgentService(
    configStore: policyConfigStore,
    sessionStore: policySessionStore,
    provider: policyProvider,
    toolRuntime: ToolRuntime(root: policyTemp),
  );
  final policyAllowed = await policyService.runTurn(
    message: 'try shell',
    sessionId: 'remembered',
  );
  if (policyAllowed.reply != 'policy allowed final' ||
      policyProvider.index != 2) {
    throw StateError('session tool policy did not allow shell');
  }
  final deniedPolicyProvider = ScriptedProvider([
    '<tool_call>{"tool":"shell","arguments":{"command":"printf denied-by-policy"}} </tool_call>',
    'policy denied final',
  ]);
  final deniedPolicyService = AgentService(
    configStore: policyConfigStore,
    sessionStore: policySessionStore,
    provider: deniedPolicyProvider,
    toolRuntime: ToolRuntime(
      root: policyTemp,
      permissionHandler: (_) => ToolPermissionDecision.allow,
    ),
  );
  final deniedPolicy = await deniedPolicyService.runTurn(
    message: 'try shell',
    sessionId: 'default',
  );
  if (deniedPolicy.reply != 'policy denied final' ||
      deniedPolicyProvider.index != 2) {
    throw StateError('global tool policy deny flow failed');
  }
  await policyTemp.delete(recursive: true);
  await toolTemp.delete(recursive: true);

  await temp.delete(recursive: true);
}
