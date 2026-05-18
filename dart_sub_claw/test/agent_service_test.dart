import 'dart:io';

import 'package:dart_sub_claw/src/agent/agent_service.dart';
import 'package:dart_sub_claw/src/config/config_store.dart';
import 'package:dart_sub_claw/src/providers/chat_provider.dart';
import 'package:dart_sub_claw/src/sessions/chat_message.dart';
import 'package:dart_sub_claw/src/sessions/session_store.dart';

class EchoProvider implements ChatProvider {
  @override
  Future<String> complete({required List<ChatMessage> messages}) async {
    return 'echo: ${messages.last.content}';
  }

  @override
  Stream<String> completeStream({required List<ChatMessage> messages}) async* {
    yield 'echo: ';
    yield messages.last.content;
  }
}

Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('dart_sub_claw_test_');
  final service = AgentService(
    configStore: ConfigStore(home: temp),
    sessionStore: SessionStore(home: temp),
    provider: EchoProvider(),
  );

  final result = await service.runTurn(message: 'hello', sessionId: 'test');
  if (result.reply != 'echo: hello') {
    throw StateError('unexpected reply: ${result.reply}');
  }

  final messages = await SessionStore(home: temp).read('test');
  if (messages.length != 2 ||
      messages[0].role != 'user' ||
      messages[1].role != 'assistant') {
    throw StateError('session persistence failed');
  }

  final deltas = <String>[];
  final streamResult = await service.runTurnStreaming(
    message: 'stream',
    sessionId: 'stream-test',
    onDelta: deltas.add,
  );
  if (streamResult.reply != 'echo: stream' || deltas.join() != 'echo: stream') {
    throw StateError('streaming agent turn failed');
  }

  await temp.delete(recursive: true);
}
