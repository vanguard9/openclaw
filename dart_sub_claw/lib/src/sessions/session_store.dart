import 'dart:convert';
import 'dart:io';

import '../runtime/paths.dart';
import 'chat_message.dart';

class SessionStore {
  SessionStore({Directory? home}) : home = home ?? resolveAppHome();

  final Directory home;

  Directory get sessionsDir =>
      Directory('${home.path}${Platform.pathSeparator}sessions');

  File sessionFile(String sessionId) {
    final safeId = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File('${sessionsDir.path}${Platform.pathSeparator}$safeId.jsonl');
  }

  Future<List<String>> listSessionIds() async {
    if (!await sessionsDir.exists()) return [];
    final ids = <String>[];
    await for (final entity in sessionsDir.list()) {
      if (entity is File && entity.path.endsWith('.jsonl')) {
        ids.add(
            entity.uri.pathSegments.last.replaceFirst(RegExp(r'\.jsonl$'), ''));
      }
    }
    ids.sort();
    return ids;
  }

  Future<List<ChatMessage>> read(String sessionId) async {
    final file = sessionFile(sessionId);
    if (!await file.exists()) return [];
    final messages = <ChatMessage>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        messages.add(ChatMessage.fromJson(decoded.cast<String, Object?>()));
      }
    }
    return messages;
  }

  Future<void> append(String sessionId, ChatMessage message) async {
    await sessionsDir.create(recursive: true);
    await sessionFile(sessionId).writeAsString(
      '${jsonEncode(message.toJson())}\n',
      mode: FileMode.append,
    );
  }
}
