import 'dart:async';
import 'dart:convert';

import '../config/config_store.dart';
import '../providers/chat_provider.dart';
import '../providers/openai_compatible_provider.dart';
import '../sessions/chat_message.dart';
import '../sessions/session_store.dart';
import '../tools/tool_policy.dart';
import '../tools/tool_runtime.dart';
import 'cancellation.dart';

class AgentTurnResult {
  AgentTurnResult({
    required this.sessionId,
    required this.reply,
    this.metadata = ChatCompletionMetadata.empty,
  });

  final String sessionId;
  final String reply;
  final ChatCompletionMetadata metadata;
}

typedef AgentToolCallHandler = FutureOr<void> Function(ToolCall call);
typedef AgentToolResultHandler = FutureOr<void> Function(ToolResult result);

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
    ToolPermissionPolicy? toolPolicyOverride,
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
    final completion = await _completeWithTools(
      provider: provider,
      messages: messages,
      sessionId: sessionId,
      toolPolicy:
          toolPolicyOverride ?? envConfig.toolPolicy.toPermissionPolicy(),
      cancellationToken: cancellationToken,
    );
    cancellationToken?.throwIfCancelled();
    await sessionStore.append(
        sessionId, ChatMessage(role: 'assistant', content: completion.content));

    return AgentTurnResult(
      sessionId: sessionId,
      reply: completion.content,
      metadata: completion.metadata,
    );
  }

  Future<AgentTurnResult> runTurnStreaming({
    required String message,
    required FutureOr<void> Function(String delta) onDelta,
    AgentToolCallHandler? onToolCall,
    AgentToolResultHandler? onToolResult,
    String sessionId = 'default',
    String? environment,
    ToolPermissionPolicy? toolPolicyOverride,
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
    final completion = await _completeStreamingWithTools(
      provider: provider,
      messages: messages,
      sessionId: sessionId,
      toolPolicy:
          toolPolicyOverride ?? envConfig.toolPolicy.toPermissionPolicy(),
      cancellationToken: cancellationToken,
      onDelta: onDelta,
      onToolCall: onToolCall,
      onToolResult: onToolResult,
    );
    cancellationToken?.throwIfCancelled();
    await sessionStore.append(
        sessionId, ChatMessage(role: 'assistant', content: completion.content));

    return AgentTurnResult(
      sessionId: sessionId,
      reply: completion.content,
      metadata: completion.metadata,
    );
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

  Future<ChatCompletionResult> _completeWithTools({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required String sessionId,
    required ToolPermissionPolicy toolPolicy,
    required CancellationToken? cancellationToken,
  }) async {
    final working = List<ChatMessage>.from(messages);
    for (var step = 0; step <= defaultMaxToolSteps; step += 1) {
      cancellationToken?.throwIfCancelled();
      final completion = await _completeOneMessage(
        provider: provider,
        messages: working,
        cancellationToken: cancellationToken,
      );
      final call = toolRuntime.parseToolCall(completion.content);
      if (call == null) {
        return completion;
      }
      if (step >= defaultMaxToolSteps) {
        return const ChatCompletionResult(
          content: 'Tool limit reached before a final answer was produced.',
        );
      }
      working.add(ChatMessage(role: 'assistant', content: completion.content));
      final result = await toolRuntime.run(
        call,
        policy: toolPolicy,
        sessionId: sessionId,
      );
      working.add(_toolResultMessage(result));
    }
    return const ChatCompletionResult(
      content: 'Tool limit reached before a final answer was produced.',
    );
  }

  Future<ChatCompletionResult> _completeStreamingWithTools({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required String sessionId,
    required ToolPermissionPolicy toolPolicy,
    required CancellationToken? cancellationToken,
    required FutureOr<void> Function(String delta) onDelta,
    AgentToolCallHandler? onToolCall,
    AgentToolResultHandler? onToolResult,
  }) async {
    final working = List<ChatMessage>.from(messages);
    for (var step = 0; step <= defaultMaxToolSteps; step += 1) {
      cancellationToken?.throwIfCancelled();
      final completion = await _streamOneAssistantMessage(
        provider: provider,
        messages: working,
        cancellationToken: cancellationToken,
        onDelta: onDelta,
      );
      final call = toolRuntime.parseToolCall(completion.content);
      if (call == null) {
        return completion;
      }
      if (step >= defaultMaxToolSteps) {
        const limit = 'Tool limit reached before a final answer was produced.';
        await onDelta(limit);
        return const ChatCompletionResult(content: limit);
      }
      working.add(ChatMessage(role: 'assistant', content: completion.content));
      await onToolCall?.call(call);
      final result = await toolRuntime.run(
        call,
        policy: toolPolicy,
        sessionId: sessionId,
      );
      await onToolResult?.call(result);
      working.add(_toolResultMessage(result));
    }
    const limit = 'Tool limit reached before a final answer was produced.';
    await onDelta(limit);
    return const ChatCompletionResult(content: limit);
  }

  Future<ChatCompletionResult> _completeOneMessage({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required CancellationToken? cancellationToken,
  }) async {
    if (provider is DetailedChatProvider) {
      final detailed = provider as DetailedChatProvider;
      return detailed.completeDetailed(
        messages: messages,
        cancellationToken: cancellationToken,
      );
    }
    return ChatCompletionResult(
      content: await provider.complete(
        messages: messages,
        cancellationToken: cancellationToken,
      ),
    );
  }

  Future<ChatCompletionResult> _streamOneAssistantMessage({
    required ChatProvider provider,
    required List<ChatMessage> messages,
    required CancellationToken? cancellationToken,
    required FutureOr<void> Function(String delta) onDelta,
  }) async {
    final buffer = StringBuffer();
    var metadata = ChatCompletionMetadata.empty;
    var flushed = false;
    final detailed = provider is DetailedChatProvider
        ? provider as DetailedChatProvider
        : null;
    final stream = detailed != null
        ? detailed.completeStreamDetailed(
            messages: messages,
            cancellationToken: cancellationToken,
          )
        : provider
            .completeStream(
              messages: messages,
              cancellationToken: cancellationToken,
            )
            .map((delta) => ChatStreamEvent(delta: delta));
    await for (final event in stream) {
      cancellationToken?.throwIfCancelled();
      metadata = metadata.merge(event.metadata);
      final delta = event.delta;
      if (delta.isEmpty) {
        continue;
      }
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
    return ChatCompletionResult(content: reply, metadata: metadata);
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
