import '../sessions/chat_message.dart';
import '../agent/cancellation.dart';

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
