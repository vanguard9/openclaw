import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/agent_service.dart';

class GatewayTracePublisher {
  GatewayTracePublisher({
    required this.host,
    required this.port,
    this.timeout = const Duration(milliseconds: 750),
  }) : _client = HttpClient()..connectionTimeout = timeout;

  final String host;
  final int port;
  final Duration timeout;
  final HttpClient _client;

  Uri get uri => Uri.parse('http://$host:$port/trace');

  Future<void> publish({
    required String requestId,
    required String sessionId,
    required String? environment,
    required String source,
    required AgentTraceEvent event,
  }) async {
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'requestId': requestId,
      'sessionId': sessionId,
      if (environment != null) 'environment': environment,
      'source': source,
      ...event.toJson(),
    }));
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
  }

  void close() {
    _client.close(force: true);
  }
}

String nextLocalTraceRequestId(String source) {
  final micros = DateTime.now().microsecondsSinceEpoch;
  return '${source}_$micros';
}
