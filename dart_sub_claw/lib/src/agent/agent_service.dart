import '../config/config_store.dart';
import '../providers/chat_provider.dart';
import '../providers/openai_compatible_provider.dart';
import '../sessions/chat_message.dart';
import '../sessions/session_store.dart';

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
  })  : configStore = configStore ?? ConfigStore(),
        sessionStore = sessionStore ?? SessionStore(),
        _provider = provider;

  final ConfigStore configStore;
  final SessionStore sessionStore;
  final ChatProvider? _provider;

  Future<AgentTurnResult> runTurn({
    required String message,
    String sessionId = 'default',
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('message must not be empty');
    }

    final config = await configStore.ensureExists();
    if (config.provider.kind != 'openai-compatible') {
      throw UnsupportedError(
          'Only provider.kind=openai-compatible is implemented.');
    }

    final provider = _provider ?? OpenAiCompatibleProvider(config.provider);
    final history = await sessionStore.read(sessionId);
    final userMessage = ChatMessage(role: 'user', content: trimmed);
    final messages = [...history, userMessage];

    await sessionStore.append(sessionId, userMessage);
    final reply = await provider.complete(messages: messages);
    await sessionStore.append(
        sessionId, ChatMessage(role: 'assistant', content: reply));

    return AgentTurnResult(sessionId: sessionId, reply: reply);
  }
}
