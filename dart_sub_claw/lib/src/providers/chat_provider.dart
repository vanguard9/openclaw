import '../agent/cancellation.dart';
import '../sessions/chat_message.dart';

class ChatCompletionMetadata {
  const ChatCompletionMetadata({
    this.model,
    this.finishReason,
    Map<String, Object?> usage = const {},
    Map<String, Object?> raw = const {},
  })  : usage = usage,
        raw = raw;

  static const empty = ChatCompletionMetadata();

  final String? model;
  final String? finishReason;
  final Map<String, Object?> usage;
  final Map<String, Object?> raw;

  bool get isEmpty =>
      model == null && finishReason == null && usage.isEmpty && raw.isEmpty;

  ChatCompletionMetadata merge(ChatCompletionMetadata next) {
    if (next.isEmpty) {
      return this;
    }
    return ChatCompletionMetadata(
      model: next.model ?? model,
      finishReason: next.finishReason ?? finishReason,
      usage: next.usage.isNotEmpty ? next.usage : usage,
      raw: {
        ...raw,
        ...next.raw,
      },
    );
  }

  Map<String, Object?> toJson() => {
        if (model != null) 'model': model,
        if (finishReason != null) 'finishReason': finishReason,
        if (usage.isNotEmpty) 'usage': usage,
        if (raw.isNotEmpty) 'raw': raw,
      };
}

class ChatCompletionResult {
  const ChatCompletionResult({
    required this.content,
    this.metadata = ChatCompletionMetadata.empty,
  });

  final String content;
  final ChatCompletionMetadata metadata;
}

class ChatStreamEvent {
  const ChatStreamEvent({
    this.delta = '',
    this.metadata = ChatCompletionMetadata.empty,
  });

  final String delta;
  final ChatCompletionMetadata metadata;
}

abstract interface class ChatProvider {
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  });

  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  });
}

abstract interface class DetailedChatProvider {
  Future<ChatCompletionResult> completeDetailed({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  });

  Stream<ChatStreamEvent> completeStreamDetailed({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  });
}
