import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/cancellation.dart';
import '../config/app_config.dart';
import '../sessions/chat_message.dart';
import 'chat_provider.dart';

class ProviderTimeoutException implements Exception {
  ProviderTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OpenAiCompatibleProvider implements ChatProvider {
  OpenAiCompatibleProvider(this.config);

  final ProviderConfig config;

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final apiKey = _resolveApiKey();
    final uri = _chatCompletionsUri();
    return _withRetries(
      cancellationToken: cancellationToken,
      operation: () async {
        final client = _createClient(cancellationToken);
        try {
          cancellationToken?.throwIfCancelled();
          final request = await _withTimeout(
            client.postUrl(uri),
            'Provider timed out opening request.',
          );
          cancellationToken?.throwIfCancelled();
          request.headers.contentType = ContentType.json;
          request.headers
              .set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
          request.write(jsonEncode(_payload(messages)));

          final response = await _withTimeout(
            request.close(),
            'Provider timed out waiting for response.',
          );
          cancellationToken?.throwIfCancelled();
          final body = await _withTimeout(
            response.transform(utf8.decoder).join(),
            'Provider timed out reading response.',
          );
          cancellationToken?.throwIfCancelled();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw _ProviderHttpException(response.statusCode, body, uri);
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
      },
    );
  }

  HttpClient _createClient(CancellationToken? cancellationToken) {
    final client = HttpClient();
    client.connectionTimeout = _timeout;
    unawaited(
        cancellationToken?.cancelled.then((_) => client.close(force: true)));
    return client;
  }

  Future<T> _withRetries<T>({
    required Future<T> Function() operation,
    required CancellationToken? cancellationToken,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _maxRetries; attempt += 1) {
      cancellationToken?.throwIfCancelled();
      try {
        return await operation();
      } on Object catch (error) {
        cancellationToken?.throwIfCancelled();
        lastError = error;
        if (attempt >= _maxRetries || !_isRetryable(error)) {
          throw _normalizeProviderError(error);
        }
        await _delayBeforeRetry(attempt, cancellationToken);
      }
    }
    throw _normalizeProviderError(lastError ?? StateError('provider failed'));
  }

  Future<T> _withTimeout<T>(Future<T> future, String message) {
    return future.timeout(
      _timeout,
      onTimeout: () => throw ProviderTimeoutException(message),
    );
  }

  Future<void> _delayBeforeRetry(
    int attempt,
    CancellationToken? cancellationToken,
  ) async {
    final delayMs = config.retryBackoffMs * (1 << attempt);
    if (delayMs <= 0) {
      return;
    }
    await Future.any([
      Future<void>.delayed(Duration(milliseconds: delayMs)),
      if (cancellationToken != null) cancellationToken.cancelled,
    ]);
    cancellationToken?.throwIfCancelled();
  }

  bool _isRetryable(Object error) {
    if (error is ProviderTimeoutException) return true;
    if (error is SocketException) return true;
    if (error is HttpException) return true;
    if (error is _ProviderHttpException) {
      return error.statusCode == 429 ||
          (error.statusCode >= 500 && error.statusCode <= 599);
    }
    return false;
  }

  Object _normalizeProviderError(Object error) {
    if (error is _ProviderHttpException) {
      return HttpException(
        'Provider returned HTTP ${error.statusCode}: ${error.body}',
        uri: error.uri,
      );
    }
    return error;
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    cancellationToken?.throwIfCancelled();
    final apiKey = _resolveApiKey();
    final uri = _chatCompletionsUri();
    var receivedDelta = false;
    for (var attempt = 0; attempt <= _maxRetries; attempt += 1) {
      final client = _createClient(cancellationToken);
      try {
        cancellationToken?.throwIfCancelled();
        final request = await _withTimeout(
          client.postUrl(uri),
          'Provider timed out opening stream request.',
        );
        cancellationToken?.throwIfCancelled();
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
        request.write(jsonEncode(_payload(messages, stream: true)));

        final response = await _withTimeout(
          request.close(),
          'Provider timed out waiting for stream response.',
        );
        cancellationToken?.throwIfCancelled();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final body = await _withTimeout(
            response.transform(utf8.decoder).join(),
            'Provider timed out reading stream error response.',
          );
          throw _ProviderHttpException(response.statusCode, body, uri);
        }

        final lines = response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(
              _timeout,
              onTimeout: (sink) => sink.addError(ProviderTimeoutException(
                  'Provider timed out waiting for stream data.')),
            );
        await for (final line in lines) {
          cancellationToken?.throwIfCancelled();
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) {
            continue;
          }
          final data = trimmed.substring('data:'.length).trim();
          if (data == '[DONE]') {
            return;
          }
          final delta = _parseStreamDelta(data);
          if (delta != null && delta.isNotEmpty) {
            receivedDelta = true;
            cancellationToken?.throwIfCancelled();
            yield delta;
          }
        }
        return;
      } on Object catch (error) {
        cancellationToken?.throwIfCancelled();
        if (receivedDelta || attempt >= _maxRetries || !_isRetryable(error)) {
          throw _normalizeProviderError(error);
        }
        await _delayBeforeRetry(attempt, cancellationToken);
      } finally {
        client.close(force: true);
      }
    }
  }

  Duration get _timeout =>
      Duration(seconds: config.timeoutSeconds < 1 ? 1 : config.timeoutSeconds);

  int get _maxRetries => config.maxRetries < 0 ? 0 : config.maxRetries;

  Uri _chatCompletionsUri() {
    return Uri.parse(
        '${config.baseUrl.replaceFirst(RegExp(r'/$'), '')}/chat/completions');
  }

  Map<String, Object?> _payload(
    List<ChatMessage> messages, {
    bool stream = false,
  }) {
    return {
      'model': config.model,
      'messages': messages
          .map((message) => {
                'role': message.role,
                'content': message.content,
              })
          .toList(),
      if (stream) 'stream': true,
    };
  }

  String? _parseStreamDelta(String data) {
    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      return null;
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      return null;
    }
    final first = choices.first;
    if (first is! Map) {
      return null;
    }
    final delta = first['delta'];
    if (delta is Map && delta['content'] is String) {
      return delta['content'] as String;
    }
    return null;
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

class _ProviderHttpException implements Exception {
  _ProviderHttpException(this.statusCode, this.body, this.uri);

  final int statusCode;
  final String body;
  final Uri uri;
}
