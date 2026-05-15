import '../sessions/chat_message.dart';

abstract interface class ChatProvider {
  Future<String> complete({
    required List<ChatMessage> messages,
  });
}
