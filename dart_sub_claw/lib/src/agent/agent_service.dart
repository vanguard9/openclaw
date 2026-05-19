import 'dart:async';
import 'dart:convert';

import '../config/config_store.dart';
import '../providers/chat_provider.dart';
import '../providers/openai_compatible_provider.dart';
import '../sessions/chat_message.dart';
import '../sessions/session_store.dart';
import '../tools/tool_runtime.dart';
import 'cancellation.dart';

class AgentTurnResult {
  AgentTurnResult({
    required this.sessionId,
    required this.reply,
  });

  final String sessionId;
  final String reply;
}

class AgentService {
  AgentService({
    ConfigStore? configStore,
    SessionStore? sessionStore,
    ChatProvider? provider,
    ToolRuntime? toolRuntime,
  })  : configStore = configStore ?? ConfigStore(),
        sessionStore = sessionStore ?? SessionStore(),
        toolRuntime = toolRuntime ?? ToolRuntime(),
        _provider = provider;

  final ConfigStore configStore;
  final SessionStore sessionStore;
  final ToolRuntime toolRuntime;
  final ChatProvider? _provider;

  Future<AgentTurnResult> runTurn({
    required String message,
    String sessionId = 'default',
    String? environment,
    CancellationToken? cancellationToken,
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('message must not be empty');
    }

    final config = await configStore.ensureExists();
    final envConfig = config.resolveEnvironment(environment);
    if (envConfig.provider.kind != 'openai-compatible') {
      throw UnsupportedError(
          'Only provider.kind=openai-compatible is implemented.');
    }

    final provider = _provider ?? OpenAiCompatibleProvider(envConfig.provider);
    final history = await sessionStore.read(sessionId);
    final userMessage = ChatMessage(role: 'user', content: trimmed);
    final messages = _initialMessages(history, userMessage);

    cancellationToken?.throwIfCancelled();
    await sessionStore.append(sessionId, userMessage);
    final reply = await _completeWithTools(
      provider: provider,
      messages: messages,
      cancellationToken: cancellationToken,
    );
    cancellationToken?.throwIfCancelled();
    await sessionStore.append(
        sessionId, ChatMessage(role: 'assistant', content: reply));

    return AgentTurnResult(sessionId: sessionId, reply: reply);
  }

  Future<AgentTurnResult> runTurnStreaming({
    required String message,
    required FutureOr<void> Function(String delta) onDelta,
    String sessionId = 'default',
    String? environment,
    CancellationToken? cancellationToken,
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('message must not be empty');
    }

    final config = await configStore.ensureExists();
    final envConfig = config.resolveEnvironment(environment);
    if (envConfig.provider.kind != 'openai-compatible') {
      throw UnsupportedError(
          'Only provider.kind=openai-compatible is implemented.');
    }

    final provider = _provider ?? OpenAiCompatibleProvider(envConfig.provider);
    final history = await sessionStore.read(sessionId);
    final userMessage = ChatMessage(role: 'user', content: trimmed);
    final messages = _initialMessages(history, userMessage);

    cancellationToken?.throwIfCancelled();
    await sessionStore.append(sessionId, userMessage);
    final reply = await _completeStreamingWithTools(
      provider: provider,
      messages: messages,
      cancellationToken: cancellationToken,
      onDelta: onDelta,
    );
    cancellationToken?.throwIfCancelled();
    await sessionStore.append(
        sessionId, ChatMessage(role: 'assistant', content: reply));

    return AgentTurnResult(sessionId: sessionId, reply: reply);
  }

  List<ChatMessage> _initialMessages(
    List<ChatMessage> history,
    ChatMessage userMessage,
  ) {
    return [
      ChatMessage(role: 'system', content: toolRuntime.systemPrompt),
      ...history,
      userMessage,
    ];
  }

  Future<String> _completeWithTools({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required CancellationToken? cancellationToken,
  }) async {
    final working = List<ChatMessage>.from(messages);
    for (var step = 0; step <= defaultMaxToolSteps; step += 1) {
      cancellationToken?.throwIfCancelled();
      final reply = await provider.complete(
        messages: working,
        cancellationToken: cancellationToken,
      );
      final call = toolRuntime.parseToolCall(reply);
      if (call == null) {
        return reply;
      }
      if (step >= defaultMaxToolSteps) {
        return 'Tool limit reached before a final answer was produced.';
      }
      working.add(ChatMessage(role: 'assistant', content: reply));
      final result = await toolRuntime.run(call);
      working.add(_toolResultMessage(result));
    }
    return 'Tool limit reached before a final answer was produced.';
  }

  Future<String> _completeStreamingWithTools({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required CancellationToken? cancellationToken,
    required FutureOr<void> Function(String delta) onDelta,
  }) async {
    final working = List<ChatMessage>.from(messages);
    for (var step = 0; step <= defaultMaxToolSteps; step += 1) {
      cancellationToken?.throwIfCancelled();
      final reply = await _streamOneAssistantMessage(
        provider: provider,
        messages: working,
        cancellationToken: cancellationToken,
        onDelta: onDelta,
      );
      final call = toolRuntime.parseToolCall(reply);
      if (call == null) {
        return reply;
      }
      if (step >= defaultMaxToolSteps) {
        const limit = 'Tool limit reached before a final answer was produced.';
        await onDelta(limit);
        return limit;
      }
      working.add(ChatMessage(role: 'assistant', content: reply));
      final result = await toolRuntime.run(call);
      working.add(_toolResultMessage(result));
    }
    const limit = 'Tool limit reached before a final answer was produced.';
    await onDelta(limit);
    return limit;
  }

  Future<String> _streamOneAssistantMessage({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required CancellationToken? cancellationToken,
    required FutureOr<void> Function(String delta) onDelta,
  }) async {
    final buffer = StringBuffer();
    var flushed = false;
    await for (final delta in provider.completeStream(
      messages: messages,
      cancellationToken: cancellationToken,
    )) {
      cancellationToken?.throwIfCancelled();
      buffer.write(delta);
      if (!flushed && !_couldBeToolCallPrefix(buffer.toString())) {
        flushed = true;
        await onDelta(buffer.toString());
        continue;
      }
      if (flushed) {
        await onDelta(delta);
      }
    }
    final reply = buffer.toString();
    if (!flushed && toolRuntime.parseToolCall(reply) == null) {
      await onDelta(reply);
    }
    return reply;
  }

  bool _couldBeToolCallPrefix(String value) {
    const marker = '<tool_call>';
    final trimmed = value.trimLeft();
    return marker.startsWith(trimmed) || trimmed.startsWith(marker);
  }

  ChatMessage _toolResultMessage(ToolResult result) {
    const encoder = JsonEncoder.withIndent('  ');
    return ChatMessage(
      role: 'user',
      content:
          'Tool result:\n${encoder.convert(result.toJson())}\nContinue with the final answer or request another tool.',
    );
  }
}
