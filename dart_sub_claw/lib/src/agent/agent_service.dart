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

class AgentTraceEvent {
  const AgentTraceEvent({
    required this.type,
    this.data = const {},
  });

  final String type;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'type': type,
        if (data.isNotEmpty) 'data': data,
      };
}

typedef AgentToolCallHandler = FutureOr<void> Function(ToolCall call);
typedef AgentToolResultHandler = FutureOr<void> Function(ToolResult result);
typedef AgentTraceHandler = FutureOr<void> Function(AgentTraceEvent event);

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
    AgentTraceHandler? onTrace,
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
      onTrace: onTrace,
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
    AgentTraceHandler? onTrace,
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
      onTrace: onTrace,
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
    AgentTraceHandler? onTrace,
    required CancellationToken? cancellationToken,
  }) async {
    final working = List<ChatMessage>.from(messages);
    for (var step = 0; step <= defaultMaxToolSteps; step += 1) {
      cancellationToken?.throwIfCancelled();
      await _emitTrace(onTrace, _llmRequestTrace(step, working, false));
      final completion = await _completeOneMessage(
        provider: provider,
        messages: working,
        cancellationToken: cancellationToken,
      );
      await _emitTrace(onTrace, _llmResponseTrace(step, completion));
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
      await _emitTrace(onTrace, _toolCallTrace(step, call));
      final result = await toolRuntime.run(
        call,
        policy: toolPolicy,
        sessionId: sessionId,
      );
      await _emitTrace(onTrace, _toolResultTrace(step, result));
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
    AgentTraceHandler? onTrace,
  }) async {
    final working = List<ChatMessage>.from(messages);
    for (var step = 0; step <= defaultMaxToolSteps; step += 1) {
      cancellationToken?.throwIfCancelled();
      await _emitTrace(onTrace, _llmRequestTrace(step, working, true));
      final completion = await _streamOneAssistantMessage(
        provider: provider,
        messages: working,
        cancellationToken: cancellationToken,
        onDelta: onDelta,
        onTrace: onTrace,
        traceStep: step,
      );
      await _emitTrace(onTrace, _llmResponseTrace(step, completion));
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
      await _emitTrace(onTrace, _toolCallTrace(step, call));
      await onToolCall?.call(call);
      final result = await toolRuntime.run(
        call,
        policy: toolPolicy,
        sessionId: sessionId,
      );
      await _emitTrace(onTrace, _toolResultTrace(step, result));
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
    AgentTraceHandler? onTrace,
    required int traceStep,
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
      await _emitTrace(
        onTrace,
        AgentTraceEvent(
          type: 'llm.delta',
          data: {
            'step': traceStep,
            'delta': delta,
          },
        ),
      );
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

  AgentTraceEvent _llmRequestTrace(
    int step,
    List<ChatMessage> messages,
    bool stream,
  ) {
    return AgentTraceEvent(
      type: 'llm.request',
      data: {
        'step': step,
        'stream': stream,
        'messages': _messagesToProviderJson(messages),
      },
    );
  }

  AgentTraceEvent _llmResponseTrace(
    int step,
    ChatCompletionResult completion,
  ) {
    return AgentTraceEvent(
      type: 'llm.response',
      data: {
        'step': step,
        'content': completion.content,
        if (!completion.metadata.isEmpty)
          'metadata': completion.metadata.toJson(),
      },
    );
  }

  AgentTraceEvent _toolCallTrace(int step, ToolCall call) {
    return AgentTraceEvent(
      type: 'tool.call',
      data: {
        'step': step,
        'tool': call.tool,
        'arguments': call.arguments,
      },
    );
  }

  AgentTraceEvent _toolResultTrace(int step, ToolResult result) {
    return AgentTraceEvent(
      type: 'tool.result',
      data: {
        'step': step,
        'result': result.toJson(),
      },
    );
  }

  List<Map<String, Object?>> _messagesToProviderJson(
    List<ChatMessage> messages,
  ) {
    return [
      for (final message in messages)
        {
          'role': message.role,
          'content': message.content,
        },
    ];
  }

  Future<void> _emitTrace(
    AgentTraceHandler? onTrace,
    AgentTraceEvent event,
  ) async {
    await onTrace?.call(event);
  }
}
