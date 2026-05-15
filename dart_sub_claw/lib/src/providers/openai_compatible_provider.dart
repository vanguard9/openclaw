import 'dart:convert';
import 'dart:io';

import '../config/app_config.dart';
import '../sessions/chat_message.dart';
import 'chat_provider.dart';

class OpenAiCompatibleProvider implements ChatProvider {
  OpenAiCompatibleProvider(this.config);

  final ProviderConfig config;

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
  }) async {
    final apiKey = _resolveApiKey();
    final uri = Uri.parse(
        '${config.baseUrl.replaceFirst(RegExp(r'/$'), '')}/chat/completions');
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.write(jsonEncode({
        'model': config.model,
        'messages': messages
            .map((message) => {
                  'role': message.role,
                  'content': message.content,
                })
            .toList(),
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
            'Provider returned HTTP ${response.statusCode}: $body',
            uri: uri);
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw FormatException('Provider response must be a JSON object.');
      }
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map) {
          final message = first['message'];
          if (message is Map && message['content'] is String) {
            return message['content'] as String;
          }
        }
      }
      throw FormatException(
          'Provider response did not include choices[0].message.content.');
    } finally {
      client.close(force: true);
    }
  }

  String _resolveApiKey() {
    final explicit = config.apiKey;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final fromEnv = Platform.environment[config.apiKeyEnv];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return fromEnv;
    }
    throw StateError(
      'Missing provider API key. Set ${config.apiKeyEnv} or run: '
      'dartsub config set provider.apiKey <key>',
    );
  }
}
