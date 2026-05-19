import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_sub_claw/src/config/app_config.dart';
import 'package:dart_sub_claw/src/config/config_store.dart';
import 'package:dart_sub_claw/src/doctor/doctor.dart';
import 'package:dart_sub_claw/src/providers/openai_compatible_provider.dart';
import 'package:dart_sub_claw/src/sessions/chat_message.dart';
import 'package:dart_sub_claw/src/sessions/session_store.dart';

Future<void> main() async {
  await _testNonStreamingRetries429AndSucceeds();
  await _testNonStreamingTimeout();
  await _testStreamingRetriesBeforeFirstDelta();
  await _testDoctorValidatesProviderRuntimeConfig();
}

Future<void> _testNonStreamingRetries429AndSucceeds() async {
  var calls = 0;
  final server = await _startServer((request) async {
    calls += 1;
    if (calls == 1) {
      request.response.statusCode = 429;
      request.response.write('rate limited');
      await request.response.close();
      return;
    }
    await _writeJson(request.response, {
      'choices': [
        {
          'message': {'content': 'retried ok'},
        }
      ],
    });
  });

  try {
    final provider = OpenAiCompatibleProvider(_providerFor(server.port));
    final reply = await provider.complete(
      messages: [ChatMessage(role: 'user', content: 'hello')],
    );
    if (reply != 'retried ok' || calls != 2) {
      throw StateError(
          'retry did not succeed as expected: $reply calls=$calls');
    }
  } finally {
    await server.close(force: true);
  }
}

Future<void> _testNonStreamingTimeout() async {
  final server = await _startServer((request) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    await _writeJson(request.response, {
      'choices': [
        {
          'message': {'content': 'too late'},
        }
      ],
    });
  });

  try {
    final provider = OpenAiCompatibleProvider(_providerFor(
      server.port,
      timeoutSeconds: 1,
      maxRetries: 0,
    ));
    try {
      await provider.complete(
        messages: [ChatMessage(role: 'user', content: 'timeout')],
      );
      throw StateError('provider timeout was not raised');
    } on ProviderTimeoutException {
      // expected
    }
  } finally {
    await server.close(force: true);
  }
}

Future<void> _testStreamingRetriesBeforeFirstDelta() async {
  var calls = 0;
  final server = await _startServer((request) async {
    calls += 1;
    if (calls == 1) {
      request.response.statusCode = 500;
      request.response.write('temporary failure');
      await request.response.close();
      return;
    }
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    request.response.write(
      'data: {"choices":[{"delta":{"content":"stream ok"}}]}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });

  try {
    final provider = OpenAiCompatibleProvider(_providerFor(server.port));
    final deltas = <String>[];
    await for (final delta in provider.completeStream(
      messages: [ChatMessage(role: 'user', content: 'stream')],
    )) {
      deltas.add(delta);
    }
    if (deltas.join() != 'stream ok' || calls != 2) {
      throw StateError(
          'stream retry did not succeed as expected: $deltas calls=$calls');
    }
  } finally {
    await server.close(force: true);
  }
}

Future<void> _testDoctorValidatesProviderRuntimeConfig() async {
  final temp =
      await Directory.systemTemp.createTemp('dart_sub_doctor_runtime_');
  try {
    await ConfigStore(home: temp).save(AppConfig(
      provider: ProviderConfig(
        apiKey: 'test-key',
        timeoutSeconds: 0,
        maxRetries: -1,
        retryBackoffMs: -1,
      ),
    ));
    final report = await DartSubDoctor(
      configStore: ConfigStore(home: temp),
      sessionStore: SessionStore(home: temp),
    ).run(DoctorOptions(skipModel: true));
    final runtime = report.checks.firstWhere(
      (check) => check.name == 'provider runtime',
      orElse: () => throw StateError('missing provider runtime doctor check'),
    );
    if (runtime.status != DoctorStatus.fail ||
        runtime.detail == null ||
        !runtime.detail!.contains('provider.timeoutSeconds')) {
      throw StateError('unexpected provider runtime check: ${runtime.message}');
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

ProviderConfig _providerFor(
  int port, {
  int timeoutSeconds = 5,
  int maxRetries = 1,
}) {
  return ProviderConfig(
    baseUrl: 'http://127.0.0.1:$port',
    model: 'test-model',
    apiKey: 'test-key',
    timeoutSeconds: timeoutSeconds,
    maxRetries: maxRetries,
    retryBackoffMs: 0,
  );
}

Future<HttpServer> _startServer(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      if (request.uri.path != '/chat/completions') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      await handler(request);
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('$error');
      await request.response.close();
    }
  });
  return server;
}

Future<void> _writeJson(HttpResponse response, Object body) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}
