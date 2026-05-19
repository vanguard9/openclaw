import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../agent/cancellation.dart';
import '../agent/agent_service.dart';
import '../config/config_store.dart';
import '../providers/openai_compatible_provider.dart';
import '../sessions/session_store.dart';

class GatewayServer {
  GatewayServer({
    ConfigStore? configStore,
    AgentService? agentService,
    SessionStore? sessionStore,
    this.environment,
  })  : configStore = configStore ?? ConfigStore(),
        agentService = agentService ?? AgentService(),
        sessionStore = sessionStore ?? SessionStore();

  final ConfigStore configStore;
  final AgentService agentService;
  final SessionStore sessionStore;
  final String? environment;

  HttpServer? _server;
  final Set<WebSocket> _sockets = {};
  final Set<Socket> _streamSockets = {};
  static int _requestCounter = 0;

  Future<Uri> start({String? host, int? port, String? environment}) async {
    final config = await configStore.ensureExists();
    final envConfig = config.resolveEnvironment(
      environment ?? this.environment ?? Platform.environment['DARTSUB_ENV'],
    );
    final bindHost = host ?? envConfig.gateway.host;
    final bindPort = port ?? envConfig.gateway.port;
    _server = await HttpServer.bind(bindHost, bindPort);
    _server!.listen(_handleRequest);
    return Uri.parse('http://$bindHost:${_server!.port}');
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      await socket.close();
    }
    for (final socket in _streamSockets.toList()) {
      socket.destroy();
    }
    await _server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final requestId = _nextRequestId();
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
          await _jsonError(
            request,
            requestId: requestId,
            code: 'validation_error',
            message: 'message is required',
            statusCode: 400,
          );
          return;
        }
        final sessionId = payload['sessionId'] as String? ?? 'default';
        final environment =
            payload['environment'] as String? ?? this.environment;
        _broadcast({
          'type': 'agent.started',
          'requestId': requestId,
          'sessionId': sessionId,
        });
        final AgentTurnResult result;
        try {
          result = await agentService.runTurn(
            message: message,
            sessionId: sessionId,
            environment: environment,
          );
        } catch (error) {
          final code = _providerErrorCode(error);
          final event = {
            'type': 'error',
            'requestId': requestId,
            'sessionId': sessionId,
            'code': code,
            'message': '$error',
          };
          _broadcast(event);
          await _jsonError(
            request,
            requestId: requestId,
            code: code,
            message: '$error',
            statusCode: 500,
          );
          return;
        }
        final response = {
          'requestId': requestId,
          'sessionId': result.sessionId,
          'reply': result.reply,
          if (!result.metadata.isEmpty) 'metadata': result.metadata.toJson(),
        };
        _broadcast({'type': 'agent.completed', ...response});
        await _json(request, response);
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/agent/stream') {
        await _handleAgentStream(request, requestId);
        return;
      }

      await _jsonError(
        request,
        requestId: requestId,
        code: 'not_found',
        message: 'not found',
        statusCode: 404,
      );
    } catch (error, stackTrace) {
      final code = error is _GatewayException ? error.code : 'internal_error';
      final message = error is _GatewayException ? error.message : '$error';
      _broadcast({
        'type': 'error',
        'requestId': requestId,
        'code': code,
        'message': message,
      });
      await _jsonError(
        request,
        requestId: requestId,
        code: code,
        message: message,
        statusCode: error is _GatewayException ? error.statusCode : 500,
      );
      stderr.writeln(stackTrace.toString().split('\n').take(8).join('\n'));
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final Object? decoded;
    try {
      decoded = jsonDecode(body.isEmpty ? '{}' : body);
    } on FormatException catch (error) {
      throw _GatewayException(
        code: 'validation_error',
        message: 'invalid JSON body: ${error.message}',
        statusCode: 400,
      );
    }
    if (decoded is! Map) {
      throw _GatewayException(
        code: 'validation_error',
        message: 'JSON body must be an object',
        statusCode: 400,
      );
    }
    return decoded.cast<String, Object?>();
  }

  Future<void> _handleAgentStream(
    HttpRequest request,
    String requestId,
  ) async {
    final payload = await _readJson(request);
    final message = payload['message'];
    if (message is! String || message.trim().isEmpty) {
      await _jsonError(
        request,
        requestId: requestId,
        code: 'validation_error',
        message: 'message is required',
        statusCode: 400,
      );
      return;
    }

    final sessionId = payload['sessionId'] as String? ?? 'default';
    final environment = payload['environment'] as String? ?? this.environment;
    final cancellation = CancellationController();
    request.response.statusCode = 200;
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    request.response.headers.set(HttpHeaders.connectionHeader, 'close');
    request.response.headers.set(HttpHeaders.transferEncodingHeader, 'chunked');
    final socket = await request.response.detachSocket();
    _streamSockets.add(socket);
    var responseStarted = false;
    var closingNormally = false;
    final socketInput = socket.listen(
      (_) {},
      onDone: () {
        if (responseStarted && !closingNormally) {
          cancellation.cancel();
        }
      },
      onError: (_) {
        if (responseStarted && !closingNormally) {
          cancellation.cancel();
        }
      },
      cancelOnError: true,
    );

    var queuedWrites = Future<void>.value();
    Future<void> queueChunk(String chunk) {
      final next = queuedWrites.then((_) async {
        cancellation.token.throwIfCancelled();
        final bytes = utf8.encode(chunk);
        socket.write('${bytes.length.toRadixString(16)}\r\n');
        socket.add(bytes);
        socket.write('\r\n');
        await socket.flush();
      });
      queuedWrites = next.catchError((_) {
        cancellation.cancel();
      });
      return next;
    }

    Future<void> closeChunks() async {
      closingNormally = true;
      socket.write('0\r\n\r\n');
      await socket.flush();
      socket.destroy();
    }

    Future<void> sendEvent(String event, Map<String, Object?> data) async {
      await queueChunk(
        'event: $event\n'
        'data: ${jsonEncode({'type': event, ...data})}\n\n',
      );
      responseStarted = true;
    }

    Future<void> sendHeartbeat() async {
      await queueChunk(': ping\n\n');
    }

    final heartbeat = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!cancellation.isCancelled) {
        unawaited(sendHeartbeat());
      }
    });

    try {
      _broadcast({
        'type': 'agent.started',
        'requestId': requestId,
        'sessionId': sessionId,
      });
      await sendEvent('started', {
        'requestId': requestId,
        'sessionId': sessionId,
      });
      final result = await agentService.runTurnStreaming(
        message: message,
        sessionId: sessionId,
        environment: environment,
        cancellationToken: cancellation.token,
        onDelta: (delta) async {
          await sendEvent('delta', {
            'requestId': requestId,
            'sessionId': sessionId,
            'delta': delta,
          });
          _broadcast({
            'type': 'agent.delta',
            'requestId': requestId,
            'sessionId': sessionId,
            'delta': delta,
          });
        },
      );
      await queuedWrites;
      cancellation.token.throwIfCancelled();
      final completed = {
        'requestId': requestId,
        'sessionId': result.sessionId,
        'reply': result.reply,
        if (!result.metadata.isEmpty) 'metadata': result.metadata.toJson(),
      };
      _broadcast({'type': 'agent.completed', ...completed});
      await sendEvent('completed', completed);
      await closeChunks();
    } on CancelledException {
      final event = {
        'requestId': requestId,
        'sessionId': sessionId,
        'code': 'cancelled',
        'message': 'request cancelled',
      };
      _broadcast({'type': 'agent.cancelled', ...event});
      if (!cancellation.isCancelled) {
        await sendEvent('cancelled', event);
        await closeChunks();
      }
    } catch (error) {
      final code = _providerErrorCode(error);
      final event = {
        'requestId': requestId,
        'sessionId': sessionId,
        'code': code,
        'message': '$error',
      };
      _broadcast({'type': 'error', ...event});
      if (!cancellation.isCancelled) {
        await sendEvent('error', event);
        await closeChunks();
      }
    } finally {
      heartbeat.cancel();
      await socketInput.cancel();
      _streamSockets.remove(socket);
      socket.destroy();
    }
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

  Future<void> _jsonError(
    HttpRequest request, {
    required String requestId,
    required String code,
    required String message,
    required int statusCode,
  }) {
    return _json(
      request,
      {
        'requestId': requestId,
        'code': code,
        'message': message,
      },
      statusCode: statusCode,
    );
  }

  void _broadcast(Map<String, Object?> event) {
    final encoded = jsonEncode(event);
    for (final socket in _sockets.toList()) {
      socket.add(encoded);
    }
  }

  static String _nextRequestId() {
    final count = _requestCounter++;
    final micros = DateTime.now().microsecondsSinceEpoch;
    return 'req_${micros}_$count';
  }

  static String _providerErrorCode(Object error) {
    return error is ProviderTimeoutException
        ? 'provider_timeout'
        : 'provider_error';
  }
}

class _GatewayException implements Exception {
  _GatewayException({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => '$code: $message';
}
