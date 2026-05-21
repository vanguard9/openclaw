import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_sub_claw/src/config/app_config.dart';
import 'package:dart_sub_claw/src/config/config_store.dart';
import 'package:dart_sub_claw/src/doctor/doctor.dart';
import 'package:dart_sub_claw/src/providers/chat_provider.dart';
import 'package:dart_sub_claw/src/providers/openai_compatible_provider.dart';
import 'package:dart_sub_claw/src/sessions/chat_message.dart';
import 'package:dart_sub_claw/src/sessions/session_store.dart';
import 'package:dart_sub_claw/src/tools/tool_policy.dart';
import 'package:dart_sub_claw/src/tui/tui_strings.dart';

Future<void> main() async {
  await _testNonStreamingMetadata();
  await _testNonStreamingRetries429AndSucceeds();
  await _testNonStreamingTimeout();
  await _testStreamingMetadata();
  await _testStreamingRetriesBeforeFirstDelta();
  await _testConfigStoresToolPolicy();
  await _testDoctorValidatesProviderRuntimeConfig();
  await _testDoctorReportsToolPolicy();
}

Future<void> _testNonStreamingMetadata() async {
  final server = await _startServer((request) async {
    await _writeJson(request.response, {
      'id': 'chatcmpl-test',
      'object': 'chat.completion',
      'created': 1770000000,
      'model': 'metadata-model',
      'system_fingerprint': 'fp_test',
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {'content': 'metadata ok'},
        }
      ],
      'usage': {
        'prompt_tokens': 3,
        'completion_tokens': 2,
        'total_tokens': 5,
      },
    });
  });

  try {
    final provider = OpenAiCompatibleProvider(_providerFor(server.port));
    final result = await provider.completeDetailed(
      messages: [ChatMessage(role: 'user', content: 'hello')],
    );
    if (result.content != 'metadata ok' ||
        result.metadata.model != 'metadata-model' ||
        result.metadata.finishReason != 'stop' ||
        result.metadata.usage['total_tokens'] != 5 ||
        result.metadata.raw['id'] != 'chatcmpl-test' ||
        result.metadata.raw['system_fingerprint'] != 'fp_test') {
      throw StateError('metadata parse failed: ${result.metadata.toJson()}');
    }
  } finally {
    await server.close(force: true);
  }
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

Future<void> _testStreamingMetadata() async {
  final server = await _startServer((request) async {
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    request.response.write(
      'data: ${jsonEncode({
            'id': 'chunk-1',
            'model': 'stream-model',
            'choices': [
              {
                'delta': {'content': 'stream '},
              }
            ],
          })}\n\n',
    );
    request.response.write(
      'data: ${jsonEncode({
            'id': 'chunk-2',
            'model': 'stream-model',
            'choices': [
              {
                'finish_reason': 'stop',
                'delta': {'content': 'metadata'},
              }
            ],
            'usage': {
              'prompt_tokens': 4,
              'completion_tokens': 3,
              'total_tokens': 7,
            },
          })}\n\n',
    );
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });

  try {
    final provider = OpenAiCompatibleProvider(_providerFor(server.port));
    var metadata = ChatCompletionMetadata.empty;
    final deltas = <String>[];
    await for (final event in provider.completeStreamDetailed(
      messages: [ChatMessage(role: 'user', content: 'stream')],
    )) {
      deltas.add(event.delta);
      metadata = metadata.merge(event.metadata);
    }
    if (deltas.join() != 'stream metadata' ||
        metadata.model != 'stream-model' ||
        metadata.finishReason != 'stop' ||
        metadata.usage['total_tokens'] != 7 ||
        metadata.raw['id'] != 'chunk-2') {
      throw StateError('stream metadata parse failed: ${metadata.toJson()}');
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

Future<void> _testConfigStoresToolPolicy() async {
  final temp =
      await Directory.systemTemp.createTemp('dart_sub_tool_policy_config_');
  try {
    final store = ConfigStore(home: temp);
    var config = await store.setValue('toolPolicy.tools.shell', 'deny');
    if (config.toolPolicy.tools['shell'] != ToolPolicyDecision.deny) {
      throw StateError('global tool policy was not stored');
    }
    config = await store.setToolPolicyDecision(
      tool: 'write_file',
      decision: ToolPolicyDecision.allow,
      sessionId: 'session/with spaces',
    );
    final sessionPolicy = config.toolPolicy.sessions['session_with_spaces'];
    if (sessionPolicy?['write_file'] != ToolPolicyDecision.allow) {
      throw StateError('session tool policy was not stored: $sessionPolicy');
    }
    config = await store.setValue(
      'toolPolicy.sessions.test.shell',
      'allow',
      environment: 'dev',
    );
    if (config.environments['dev']?.toolPolicy.sessions['test']?['shell'] !=
        ToolPolicyDecision.allow) {
      throw StateError('environment tool policy was not stored');
    }
    config = await store.setValue('tui.locale', 'zh-CN');
    if (config.tui.locale != TuiLocalePreference.zhCn) {
      throw StateError('TUI locale was not stored');
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _testDoctorReportsToolPolicy() async {
  final temp =
      await Directory.systemTemp.createTemp('dart_sub_doctor_tool_policy_');
  try {
    await ConfigStore(home: temp).save(AppConfig(
      provider: ProviderConfig(apiKey: 'test-key'),
      toolPolicy: ToolPolicyConfig(
        tools: {'shell': ToolPolicyDecision.allow},
      ),
    ));
    final report = await DartSubDoctor(
      configStore: ConfigStore(home: temp),
      sessionStore: SessionStore(home: temp),
    ).run(DoctorOptions(skipModel: true));
    final policy = report.checks.firstWhere(
      (check) => check.name == 'tool policy',
      orElse: () => throw StateError('missing tool policy doctor check'),
    );
    if (policy.status != DoctorStatus.ok ||
        !policy.message.contains('1 explicit')) {
      throw StateError('unexpected tool policy check: ${policy.message}');
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
