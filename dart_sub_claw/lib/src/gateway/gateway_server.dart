import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/agent_service.dart';
import '../config/config_store.dart';
import '../sessions/session_store.dart';

class GatewayServer {
  GatewayServer({
    ConfigStore? configStore,
    AgentService? agentService,
    SessionStore? sessionStore,
  })  : configStore = configStore ?? ConfigStore(),
        agentService = agentService ?? AgentService(),
        sessionStore = sessionStore ?? SessionStore();

  final ConfigStore configStore;
  final AgentService agentService;
  final SessionStore sessionStore;

  HttpServer? _server;
  final Set<WebSocket> _sockets = {};

  Future<Uri> start({String? host, int? port}) async {
    final config = await configStore.ensureExists();
    final bindHost = host ?? config.gateway.host;
    final bindPort = port ?? config.gateway.port;
    _server = await HttpServer.bind(bindHost, bindPort);
    _server!.listen(_handleRequest);
    return Uri.parse('http://$bindHost:$bindPort');
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      await socket.close();
    }
    await _server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/events' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _sockets.add(socket);
        socket.done.whenComplete(() => _sockets.remove(socket));
        socket.add(jsonEncode({'type': 'hello'}));
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/health') {
        await _json(request, {'ok': true, 'name': 'dart_sub_claw'});
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/sessions') {
        await _json(request, {'sessions': await sessionStore.listSessionIds()});
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/agent') {
        final payload = await _readJson(request);
        final message = payload['message'];
        if (message is! String || message.trim().isEmpty) {
          await _json(request, {'error': 'message is required'},
              statusCode: 400);
          return;
        }
        final sessionId = payload['sessionId'] as String? ?? 'default';
        _broadcast({'type': 'agent.started', 'sessionId': sessionId});
        final result =
            await agentService.runTurn(message: message, sessionId: sessionId);
        final response = {'sessionId': result.sessionId, 'reply': result.reply};
        _broadcast({'type': 'agent.completed', ...response});
        await _json(request, response);
        return;
      }

      await _json(request, {'error': 'not found'}, statusCode: 404);
    } catch (error, stackTrace) {
      _broadcast({'type': 'error', 'error': '$error'});
      await _json(
        request,
        {
          'error': '$error',
          'stack': stackTrace.toString().split('\n').take(8).join('\n'),
        },
        statusCode: 500,
      );
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final decoded = jsonDecode(body.isEmpty ? '{}' : body);
    if (decoded is! Map) {
      throw FormatException('JSON body must be an object.');
    }
    return decoded.cast<String, Object?>();
  }

  Future<void> _json(
    HttpRequest request,
    Object body, {
    int statusCode = 200,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  void _broadcast(Map<String, Object?> event) {
    final encoded = jsonEncode(event);
    for (final socket in _sockets.toList()) {
      socket.add(encoded);
    }
  }
}
