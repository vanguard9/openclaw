import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_sub_claw/src/agent/cancellation.dart';
import 'package:dart_sub_claw/src/agent/agent_service.dart';
import 'package:dart_sub_claw/src/config/config_store.dart';
import 'package:dart_sub_claw/src/gateway/gateway_server.dart';
import 'package:dart_sub_claw/src/gateway/trace_publisher.dart';
import 'package:dart_sub_claw/src/providers/chat_provider.dart';
import 'package:dart_sub_claw/src/providers/openai_compatible_provider.dart';
import 'package:dart_sub_claw/src/sessions/chat_message.dart';
import 'package:dart_sub_claw/src/sessions/session_store.dart';

class StreamingProvider implements ChatProvider, DetailedChatProvider {
  StreamingProvider(this.deltas,
      {this.metadata = ChatCompletionMetadata.empty});

  final List<String> deltas;
  final ChatCompletionMetadata metadata;

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    return (await completeDetailed(
      messages: messages,
      cancellationToken: cancellationToken,
    ))
        .content;
  }

  @override
  Future<ChatCompletionResult> completeDetailed({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return ChatCompletionResult(content: deltas.join(), metadata: metadata);
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    await for (final event in completeStreamDetailed(
      messages: messages,
      cancellationToken: cancellationToken,
    )) {
      if (event.delta.isNotEmpty) {
        yield event.delta;
      }
    }
  }

  @override
  Stream<ChatStreamEvent> completeStreamDetailed({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    for (final delta in deltas) {
      cancellationToken?.throwIfCancelled();
      yield ChatStreamEvent(delta: delta);
    }
    if (!metadata.isEmpty) {
      yield ChatStreamEvent(metadata: metadata);
    }
  }
}

class CancellableStreamingProvider implements ChatProvider {
  final Completer<void> firstDeltaSent = Completer<void>();
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) {
    throw UnsupportedError('non-streaming is not used by this test');
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    try {
      yield 'partial';
      firstDeltaSent.complete();
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        cancellationToken?.throwIfCancelled();
        yield 'x' * 65536;
      }
    } finally {
      if (cancellationToken?.isCancelled ?? false) {
        cancelled.complete();
      }
    }
  }
}

class FailingProvider implements ChatProvider {
  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) {
    throw StateError('provider failed');
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    throw StateError('provider failed');
  }
}

class TimeoutProvider implements ChatProvider {
  @override
  Future<String> complete({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) {
    throw ProviderTimeoutException('provider timed out');
  }

  @override
  Stream<String> completeStream({
    required List<ChatMessage> messages,
    CancellationToken? cancellationToken,
  }) async* {
    throw ProviderTimeoutException('provider timed out');
  }
}

Future<void> main() async {
  await _testJsonAgentRequestIdsAndValidationErrors();
  await _testProviderErrorsAreStructured();
  await _testProviderTimeoutsAreStructured();
  await _testSseStreamCompletes();
  await _testTraceStreamReceivesAgentTraceEvents();
  await _testTraceStreamReceivesPostedTraceEvents();
  await _testClientDisconnectCancelsProvider();
}

Future<void> _testJsonAgentRequestIdsAndValidationErrors() async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_gateway_json_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: StreamingProvider(
        ['json reply'],
        metadata: const ChatCompletionMetadata(
          model: 'gateway-model',
          finishReason: 'stop',
          usage: {'total_tokens': 8},
        ),
      ),
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  final client = HttpClient();
  WebSocket? socket;
  final broadcasts = <Map<String, Object?>>[];
  final completedBroadcast = Completer<void>();
  try {
    socket = await WebSocket.connect(
      uri.replace(scheme: 'ws').resolve('/events').toString(),
    );
    socket.listen((data) {
      final event = (jsonDecode(data as String) as Map).cast<String, Object?>();
      broadcasts.add(event);
      if (event['type'] == 'agent.completed' &&
          !completedBroadcast.isCompleted) {
        completedBroadcast.complete();
      }
    });

    final request = await client.postUrl(uri.resolve('/agent'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'message': 'json please',
      'sessionId': 'gateway-json',
    }));
    final response = await request.close();
    final body =
        (jsonDecode(await response.transform(utf8.decoder).join()) as Map)
            .cast<String, Object?>();
    if (response.statusCode != 200) {
      throw StateError('expected /agent HTTP 200, got ${response.statusCode}');
    }
    final requestId = body['requestId'];
    if (requestId is! String || !requestId.startsWith('req_')) {
      throw StateError('missing requestId in /agent response: $body');
    }
    if (body['reply'] != 'json reply' || body['sessionId'] != 'gateway-json') {
      throw StateError('unexpected /agent response: $body');
    }
    final metadata = body['metadata'];
    if (metadata is! Map ||
        metadata['model'] != 'gateway-model' ||
        metadata['finishReason'] != 'stop' ||
        (metadata['usage'] as Map?)?['total_tokens'] != 8) {
      throw StateError('unexpected /agent metadata: $body');
    }

    await completedBroadcast.future.timeout(const Duration(seconds: 5));
    final started = broadcasts.firstWhere(
      (event) => event['type'] == 'agent.started',
      orElse: () => throw StateError('missing agent.started broadcast'),
    );
    final completed = broadcasts.firstWhere(
      (event) => event['type'] == 'agent.completed',
      orElse: () => throw StateError('missing agent.completed broadcast'),
    );
    if (started['requestId'] != requestId ||
        completed['requestId'] != requestId) {
      throw StateError('broadcast requestId mismatch: $broadcasts');
    }
    final completedMetadata = completed['metadata'];
    if (completedMetadata is! Map ||
        completedMetadata['model'] != 'gateway-model') {
      throw StateError('broadcast metadata missing: $completed');
    }

    final invalid = await client.postUrl(uri.resolve('/agent'));
    invalid.headers.contentType = ContentType.json;
    invalid.write(jsonEncode({'sessionId': 'invalid'}));
    final invalidResponse = await invalid.close();
    final invalidBody =
        (jsonDecode(await invalidResponse.transform(utf8.decoder).join())
                as Map)
            .cast<String, Object?>();
    if (invalidResponse.statusCode != 400 ||
        invalidBody['code'] != 'validation_error' ||
        invalidBody['message'] != 'message is required' ||
        invalidBody['requestId'] is! String) {
      throw StateError('unexpected validation error: $invalidBody');
    }

    final invalidStream = await client.postUrl(uri.resolve('/agent/stream'));
    invalidStream.headers.contentType = ContentType.json;
    invalidStream.write(jsonEncode({'sessionId': 'invalid-stream'}));
    final invalidStreamResponse = await invalidStream.close();
    final invalidStreamBody =
        (jsonDecode(await invalidStreamResponse.transform(utf8.decoder).join())
                as Map)
            .cast<String, Object?>();
    if (invalidStreamResponse.statusCode != 400 ||
        invalidStreamBody['code'] != 'validation_error' ||
        invalidStreamBody['message'] != 'message is required' ||
        invalidStreamBody['requestId'] is! String) {
      throw StateError(
          'unexpected stream validation error: $invalidStreamBody');
    }
  } finally {
    await socket?.close();
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  }
}

Future<void> _testProviderErrorsAreStructured() async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_gateway_error_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: FailingProvider(),
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri.resolve('/agent'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'message': 'fail',
      'sessionId': 'gateway-error',
    }));
    final response = await request.close();
    final body =
        (jsonDecode(await response.transform(utf8.decoder).join()) as Map)
            .cast<String, Object?>();
    if (response.statusCode != 500 ||
        body['code'] != 'provider_error' ||
        body['message'] is! String ||
        body['requestId'] is! String) {
      throw StateError('unexpected provider error response: $body');
    }

    final streamRequest = await client.postUrl(uri.resolve('/agent/stream'));
    streamRequest.headers.contentType = ContentType.json;
    streamRequest.write(jsonEncode({
      'message': 'fail stream',
      'sessionId': 'gateway-stream-error',
    }));
    final streamResponse = await streamRequest.close();
    final streamBody = await streamResponse.transform(utf8.decoder).join();
    final events = _parseSseEvents(streamBody);
    if (streamResponse.statusCode != 200 ||
        events.length != 2 ||
        events.first.name != 'started' ||
        events.last.name != 'error' ||
        events.last.data['code'] != 'provider_error' ||
        events.last.data['message'] is! String ||
        events.last.data['requestId'] != events.first.data['requestId']) {
      throw StateError('unexpected provider stream error events: $events');
    }
  } finally {
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  }
}

Future<void> _testProviderTimeoutsAreStructured() async {
  final temp =
      await Directory.systemTemp.createTemp('dart_sub_gateway_timeout_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: TimeoutProvider(),
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri.resolve('/agent'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'message': 'timeout',
      'sessionId': 'gateway-timeout',
    }));
    final response = await request.close();
    final body =
        (jsonDecode(await response.transform(utf8.decoder).join()) as Map)
            .cast<String, Object?>();
    if (response.statusCode != 500 ||
        body['code'] != 'provider_timeout' ||
        body['message'] is! String ||
        body['requestId'] is! String) {
      throw StateError('unexpected timeout response: $body');
    }

    final streamRequest = await client.postUrl(uri.resolve('/agent/stream'));
    streamRequest.headers.contentType = ContentType.json;
    streamRequest.write(jsonEncode({
      'message': 'timeout stream',
      'sessionId': 'gateway-stream-timeout',
    }));
    final streamResponse = await streamRequest.close();
    final streamBody = await streamResponse.transform(utf8.decoder).join();
    final events = _parseSseEvents(streamBody);
    if (events.length != 2 ||
        events.first.name != 'started' ||
        events.last.name != 'error' ||
        events.last.data['code'] != 'provider_timeout' ||
        events.last.data['requestId'] != events.first.data['requestId']) {
      throw StateError('unexpected timeout stream events: $events');
    }
  } finally {
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  }
}

Future<void> _testSseStreamCompletes() async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_gateway_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: StreamingProvider(
        ['hello', ' ', 'world'],
        metadata: const ChatCompletionMetadata(
          model: 'stream-gateway-model',
          finishReason: 'stop',
          usage: {'total_tokens': 10},
        ),
      ),
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri.resolve('/agent/stream'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'message': 'stream please',
      'sessionId': 'gateway-stream',
    }));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError('stream did not complete'),
        );

    if (response.statusCode != 200) {
      throw StateError('expected HTTP 200, got ${response.statusCode}: $body');
    }
    final events = _parseSseEvents(body);
    final eventNames = events.map((event) => event.name).toList();
    if (eventNames.join(',') != 'started,delta,delta,delta,completed') {
      throw StateError('unexpected SSE events: $eventNames');
    }
    final requestIds = events.map((event) => event.data['requestId']).toSet();
    if (requestIds.length != 1 || requestIds.single is! String) {
      throw StateError('SSE events do not share one requestId: $requestIds');
    }
    final deltas = events
        .where((event) => event.name == 'delta')
        .map((event) => event.data['delta'])
        .join();
    if (deltas != 'hello world') {
      throw StateError('unexpected deltas: $deltas');
    }
    final completed = events.last.data;
    if (completed['reply'] != 'hello world' ||
        completed['sessionId'] != 'gateway-stream') {
      throw StateError('unexpected completed event: $completed');
    }
    final completedMetadata = completed['metadata'];
    if (completedMetadata is! Map ||
        completedMetadata['model'] != 'stream-gateway-model' ||
        completedMetadata['finishReason'] != 'stop' ||
        (completedMetadata['usage'] as Map?)?['total_tokens'] != 10) {
      throw StateError('unexpected completed metadata: $completed');
    }

    final messages = await sessionStore.read('gateway-stream');
    if (messages.length != 2 ||
        messages[0].content != 'stream please' ||
        messages[1].content != 'hello world') {
      throw StateError('streaming gateway session persistence failed');
    }
  } finally {
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  }
}

Future<void> _testTraceStreamReceivesAgentTraceEvents() async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_gateway_trace_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: StreamingProvider(['trace', ' ', 'reply']),
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  final client = HttpClient();
  StreamSubscription<String>? traceSubscription;
  try {
    final traceRequest = await client.getUrl(uri.resolve('/trace'));
    final traceResponse = await traceRequest.close();
    if (traceResponse.statusCode != 200) {
      throw StateError(
          'expected /trace HTTP 200, got ${traceResponse.statusCode}');
    }

    final traceEvents = <_SseEvent>[];
    final helloSeen = Completer<void>();
    final requestSeen = Completer<_SseEvent>();
    final deltaSeen = Completer<_SseEvent>();
    final responseSeen = Completer<_SseEvent>();
    traceSubscription = _listenForSseEvents(traceResponse, (event) {
      traceEvents.add(event);
      if (event.name == 'hello' && !helloSeen.isCompleted) {
        final captures = event.data['captures'];
        if (event.data['message'] is! String ||
            captures is! List ||
            !captures.contains('/agent/stream')) {
          throw StateError('unexpected /trace hello event: $event');
        }
        helloSeen.complete();
      }
      if (event.name != 'trace') {
        return;
      }
      switch (event.data['type']) {
        case 'llm.request':
          if (!requestSeen.isCompleted) {
            requestSeen.complete(event);
          }
        case 'llm.delta':
          if (!deltaSeen.isCompleted) {
            deltaSeen.complete(event);
          }
        case 'llm.response':
          if (!responseSeen.isCompleted) {
            responseSeen.complete(event);
          }
      }
    });

    await helloSeen.future.timeout(const Duration(seconds: 5));

    final request = await client.postUrl(uri.resolve('/agent/stream'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'message': 'trace please',
      'sessionId': 'gateway-trace',
    }));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError('stream did not complete'),
        );
    final streamEvents = _parseSseEvents(body);
    if (response.statusCode != 200 || streamEvents.last.name != 'completed') {
      throw StateError('unexpected /agent/stream trace response: $body');
    }
    final requestId = streamEvents.first.data['requestId'];
    if (requestId is! String || requestId.isEmpty) {
      throw StateError('missing stream requestId: $streamEvents');
    }

    final requestEvent =
        await requestSeen.future.timeout(const Duration(seconds: 5));
    final deltaEvent =
        await deltaSeen.future.timeout(const Duration(seconds: 5));
    final responseEvent =
        await responseSeen.future.timeout(const Duration(seconds: 5));
    for (final event in [requestEvent, deltaEvent, responseEvent]) {
      if (event.data['requestId'] != requestId ||
          event.data['sessionId'] != 'gateway-trace') {
        throw StateError('trace identifiers mismatch: $traceEvents');
      }
    }
    final requestData = requestEvent.data['data'];
    if (requestData is! Map || requestData['stream'] != true) {
      throw StateError('unexpected llm.request trace data: $requestEvent');
    }
    final deltaData = deltaEvent.data['data'];
    if (deltaData is! Map || deltaData['delta'] != 'trace') {
      throw StateError('unexpected llm.delta trace data: $deltaEvent');
    }
    final responseData = responseEvent.data['data'];
    if (responseData is! Map || responseData['content'] != 'trace reply') {
      throw StateError('unexpected llm.response trace data: $responseEvent');
    }
  } finally {
    await traceSubscription?.cancel();
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  }
}

Future<void> _testTraceStreamReceivesPostedTraceEvents() async {
  final temp =
      await Directory.systemTemp.createTemp('dart_sub_gateway_trace_post_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: StreamingProvider(['unused']),
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  final client = HttpClient();
  final publisher = GatewayTracePublisher(host: '127.0.0.1', port: uri.port);
  StreamSubscription<String>? traceSubscription;
  try {
    final traceRequest = await client.getUrl(uri.resolve('/trace'));
    final traceResponse = await traceRequest.close();
    final postedSeen = Completer<_SseEvent>();
    traceSubscription = _listenForSseEvents(traceResponse, (event) {
      if (event.name == 'trace' &&
          event.data['source'] == 'tui' &&
          !postedSeen.isCompleted) {
        postedSeen.complete(event);
      }
    });

    await publisher.publish(
      requestId: 'tui_test_request',
      sessionId: 'tui-posted-trace',
      environment: 'test',
      source: 'tui',
      event: const AgentTraceEvent(
        type: 'llm.request',
        data: {'step': 0, 'stream': true},
      ),
    );

    final event = await postedSeen.future.timeout(const Duration(seconds: 5));
    if (event.data['requestId'] != 'tui_test_request' ||
        event.data['sessionId'] != 'tui-posted-trace' ||
        event.data['environment'] != 'test' ||
        event.data['type'] != 'llm.request') {
      throw StateError('unexpected posted trace event: $event');
    }
    final data = event.data['data'];
    if (data is! Map || data['stream'] != true) {
      throw StateError('unexpected posted trace data: $event');
    }
  } finally {
    publisher.close();
    await traceSubscription?.cancel();
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  }
}

Future<void> _testClientDisconnectCancelsProvider() async {
  final temp =
      await Directory.systemTemp.createTemp('dart_sub_gateway_cancel_');
  final configStore = ConfigStore(home: temp);
  final sessionStore = SessionStore(home: temp);
  final provider = CancellableStreamingProvider();
  final server = GatewayServer(
    configStore: configStore,
    sessionStore: sessionStore,
    agentService: AgentService(
      configStore: configStore,
      sessionStore: sessionStore,
      provider: provider,
    ),
  );
  final uri = await server.start(host: '127.0.0.1', port: 0);
  Socket? socket;
  try {
    final body = jsonEncode({
      'message': 'cancel please',
      'sessionId': 'gateway-cancel',
    });
    socket = await Socket.connect('127.0.0.1', uri.port);
    socket.write(
      'POST /agent/stream HTTP/1.1\r\n'
      'Host: 127.0.0.1:${uri.port}\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: ${utf8.encode(body).length}\r\n'
      'Connection: close\r\n'
      '\r\n'
      '$body',
    );
    await socket.flush();
    final sawPartial = Completer<void>();
    socket.cast<List<int>>().transform(utf8.decoder).listen(
      (line) {
        if (line.contains('"delta":"partial"') && !sawPartial.isCompleted) {
          sawPartial.complete();
        }
      },
    );

    await sawPartial.future.timeout(const Duration(seconds: 5));
    socket.destroy();
    await provider.cancelled.future.timeout(const Duration(seconds: 10));

    final messages = await sessionStore.read('gateway-cancel');
    if (messages.length != 1 || messages.single.role != 'user') {
      throw StateError('cancelled gateway stream persisted assistant text');
    }
  } finally {
    socket?.destroy();
    await server.close();
    await temp.delete(recursive: true);
  }
}

List<_SseEvent> _parseSseEvents(String body) {
  final events = <_SseEvent>[];
  String? name;
  final data = StringBuffer();
  for (final line in const LineSplitter().convert(body)) {
    if (line.isEmpty) {
      if (name != null) {
        events.add(_SseEvent(
          name,
          (jsonDecode(data.toString()) as Map).cast<String, Object?>(),
        ));
      }
      name = null;
      data.clear();
      continue;
    }
    if (line.startsWith('event: ')) {
      name = line.substring('event: '.length);
    } else if (line.startsWith('data: ')) {
      data.write(line.substring('data: '.length));
    }
  }
  return events;
}

StreamSubscription<String> _listenForSseEvents(
  Stream<List<int>> stream,
  void Function(_SseEvent event) onEvent,
) {
  final buffer = StringBuffer();
  return stream.transform(utf8.decoder).listen((chunk) {
    buffer.write(chunk);
    var text = buffer.toString();
    var separator = text.indexOf('\n\n');
    while (separator != -1) {
      final eventBlock = text.substring(0, separator);
      text = text.substring(separator + 2);
      final event = _sseEventFromBlock(eventBlock);
      if (event != null) {
        onEvent(event);
      }
      separator = text.indexOf('\n\n');
    }
    buffer
      ..clear()
      ..write(text);
  });
}

_SseEvent? _sseEventFromBlock(String block) {
  String? name;
  final data = StringBuffer();
  for (final line in const LineSplitter().convert(block)) {
    if (line.startsWith('event: ')) {
      name = line.substring('event: '.length);
    } else if (line.startsWith('data: ')) {
      data.write(line.substring('data: '.length));
    }
  }
  if (name == null) {
    return null;
  }
  return _SseEvent(
    name,
    (jsonDecode(data.toString()) as Map).cast<String, Object?>(),
  );
}

class _SseEvent {
  _SseEvent(this.name, this.data);

  final String name;
  final Map<String, Object?> data;
}
