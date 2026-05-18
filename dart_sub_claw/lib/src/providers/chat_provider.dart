import '../sessions/chat_message.dart';

abstract interface class ChatProvider {
  Future<String> complete({
    required List<ChatMessage> messages,
  });

  Stream<String> completeStream({
    required List<ChatMessage> messages,
  });
}
