enum ToolPolicyDecision { ask, allow, deny }

const Set<String> knownToolNames = {
  'read_file',
  'write_file',
  'shell',
};

class ToolPermissionPolicy {
  ToolPermissionPolicy({
    Map<String, ToolPolicyDecision>? tools,
    Map<String, Map<String, ToolPolicyDecision>>? sessions,
  })  : tools = Map.unmodifiable(
          tools ?? const <String, ToolPolicyDecision>{},
        ),
        sessions = Map.unmodifiable(<String, Map<String, ToolPolicyDecision>>{
          for (final entry
              in (sessions ?? const <String, Map<String, ToolPolicyDecision>>{})
                  .entries)
            entry.key: Map.unmodifiable(
              Map<String, ToolPolicyDecision>.from(entry.value),
            ),
        });

  static final empty = ToolPermissionPolicy();

  final Map<String, ToolPolicyDecision> tools;
  final Map<String, Map<String, ToolPolicyDecision>> sessions;

  ToolPolicyDecision decisionFor({
    required String tool,
    String? sessionId,
  }) {
    final sessionPolicy = sessionId == null
        ? null
        : sessions[normalizeToolPolicySessionId(sessionId)];
    return sessionPolicy?[tool] ?? tools[tool] ?? ToolPolicyDecision.ask;
  }
}

ToolPolicyDecision parseToolPolicyDecision(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    'ask' => ToolPolicyDecision.ask,
    'allow' => ToolPolicyDecision.allow,
    'deny' => ToolPolicyDecision.deny,
    _ => throw FormatException(
        'tool policy decision must be ask, allow, or deny.'),
  };
}

String normalizeToolPolicySessionId(String sessionId) {
  final normalized =
      sessionId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  if (normalized.isEmpty) {
    throw ArgumentError('sessionId must not be empty.');
  }
  return normalized;
}
