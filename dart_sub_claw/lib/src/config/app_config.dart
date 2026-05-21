import '../tools/tool_policy.dart';
import '../tui/tui_strings.dart';

class AppConfig {
  AppConfig({
    ProviderConfig? provider,
    GatewayConfig? gateway,
    ToolPolicyConfig? toolPolicy,
    TuiConfig? tui,
    Map<String, EnvironmentConfig>? environments,
  })  : provider = provider ?? ProviderConfig(),
        gateway = gateway ?? GatewayConfig(),
        toolPolicy = toolPolicy ?? ToolPolicyConfig(),
        tui = tui ?? TuiConfig(),
        environments = Map.unmodifiable(environments ?? const {});

  final ProviderConfig provider;
  final GatewayConfig gateway;
  final ToolPolicyConfig toolPolicy;
  final TuiConfig tui;
  final Map<String, EnvironmentConfig> environments;

  factory AppConfig.fromJson(Map<String, Object?> json) {
    return AppConfig(
      provider: ProviderConfig.fromJson(_mapAt(json, 'provider')),
      gateway: GatewayConfig.fromJson(_mapAt(json, 'gateway')),
      toolPolicy: ToolPolicyConfig.fromJson(_mapAt(json, 'toolPolicy')),
      tui: TuiConfig.fromJson(_mapAt(json, 'tui')),
      environments: _environmentsFromJson(_mapAt(json, 'environments')),
    );
  }

  Map<String, Object?> toJson() => {
        'provider': provider.toJson(),
        'gateway': gateway.toJson(),
        'toolPolicy': toolPolicy.toJson(),
        'tui': tui.toJson(),
        if (environments.isNotEmpty)
          'environments': environments.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
      };

  AppConfig copyWith({
    ProviderConfig? provider,
    GatewayConfig? gateway,
    ToolPolicyConfig? toolPolicy,
    TuiConfig? tui,
    Map<String, EnvironmentConfig>? environments,
  }) {
    return AppConfig(
      provider: provider ?? this.provider,
      gateway: gateway ?? this.gateway,
      toolPolicy: toolPolicy ?? this.toolPolicy,
      tui: tui ?? this.tui,
      environments: environments ?? this.environments,
    );
  }

  EnvironmentConfig resolveEnvironment(String? name) {
    final normalized = normalizeEnvironmentName(name);
    if (normalized == null) {
      return EnvironmentConfig(
        provider: provider,
        gateway: gateway,
        toolPolicy: toolPolicy,
      );
    }
    return environments[normalized] ??
        EnvironmentConfig(
          provider: provider,
          gateway: gateway,
          toolPolicy: toolPolicy,
        );
  }

  AppConfig upsertEnvironment(
    String name,
    EnvironmentConfig Function(EnvironmentConfig current) update,
  ) {
    final normalized = normalizeEnvironmentName(name);
    if (normalized == null) {
      throw ArgumentError('Environment name must not be empty.');
    }
    final next = Map<String, EnvironmentConfig>.from(environments);
    next[normalized] = update(
      next[normalized] ??
          EnvironmentConfig(
            provider: provider,
            gateway: gateway,
            toolPolicy: toolPolicy,
          ),
    );
    return copyWith(environments: next);
  }
}

class EnvironmentConfig {
  EnvironmentConfig({
    ProviderConfig? provider,
    GatewayConfig? gateway,
    ToolPolicyConfig? toolPolicy,
  })  : provider = provider ?? ProviderConfig(),
        gateway = gateway ?? GatewayConfig(),
        toolPolicy = toolPolicy ?? ToolPolicyConfig();

  final ProviderConfig provider;
  final GatewayConfig gateway;
  final ToolPolicyConfig toolPolicy;

  factory EnvironmentConfig.fromJson(Map<String, Object?> json) {
    return EnvironmentConfig(
      provider: ProviderConfig.fromJson(_mapAt(json, 'provider')),
      gateway: GatewayConfig.fromJson(_mapAt(json, 'gateway')),
      toolPolicy: ToolPolicyConfig.fromJson(_mapAt(json, 'toolPolicy')),
    );
  }

  Map<String, Object?> toJson() => {
        'provider': provider.toJson(),
        'gateway': gateway.toJson(),
        'toolPolicy': toolPolicy.toJson(),
      };

  EnvironmentConfig copyWith({
    ProviderConfig? provider,
    GatewayConfig? gateway,
    ToolPolicyConfig? toolPolicy,
  }) {
    return EnvironmentConfig(
      provider: provider ?? this.provider,
      gateway: gateway ?? this.gateway,
      toolPolicy: toolPolicy ?? this.toolPolicy,
    );
  }
}

class TuiConfig {
  TuiConfig({
    this.locale = TuiLocalePreference.auto,
  });

  final TuiLocalePreference locale;

  factory TuiConfig.fromJson(Map<String, Object?> json) {
    final rawLocale = _stringAt(json, 'locale');
    return TuiConfig(
      locale: rawLocale == null
          ? TuiLocalePreference.auto
          : parseTuiLocalePreference(rawLocale),
    );
  }

  Map<String, Object?> toJson() => {
        'locale': tuiLocalePreferenceToConfig(locale),
      };

  TuiConfig copyWith({
    TuiLocalePreference? locale,
  }) {
    return TuiConfig(
      locale: locale ?? this.locale,
    );
  }
}

class ToolPolicyConfig {
  ToolPolicyConfig({
    Map<String, ToolPolicyDecision>? tools,
    Map<String, Map<String, ToolPolicyDecision>>? sessions,
  })  : tools = Map.unmodifiable(
          tools ?? const <String, ToolPolicyDecision>{},
        ),
        sessions = Map.unmodifiable(<String, Map<String, ToolPolicyDecision>>{
          for (final entry
              in (sessions ?? const <String, Map<String, ToolPolicyDecision>>{})
                  .entries)
            normalizeToolPolicySessionId(entry.key): Map.unmodifiable(
              Map<String, ToolPolicyDecision>.from(entry.value),
            ),
        });

  final Map<String, ToolPolicyDecision> tools;
  final Map<String, Map<String, ToolPolicyDecision>> sessions;

  factory ToolPolicyConfig.fromJson(Map<String, Object?> json) {
    return ToolPolicyConfig(
      tools: _decisionsFromJson(_mapAt(json, 'tools')),
      sessions: _sessionDecisionsFromJson(_mapAt(json, 'sessions')),
    );
  }

  Map<String, Object?> toJson() => {
        'tools': _decisionsToJson(tools),
        if (sessions.isNotEmpty)
          'sessions': sessions.map(
            (key, value) => MapEntry(key, _decisionsToJson(value)),
          ),
      };

  ToolPermissionPolicy toPermissionPolicy() {
    return ToolPermissionPolicy(tools: tools, sessions: sessions);
  }

  ToolPolicyConfig withToolDecision(
    String tool,
    ToolPolicyDecision decision,
  ) {
    _validateKnownTool(tool);
    return ToolPolicyConfig(
      tools: {
        ...tools,
        tool: decision,
      },
      sessions: sessions,
    );
  }

  ToolPolicyConfig withSessionToolDecision({
    required String sessionId,
    required String tool,
    required ToolPolicyDecision decision,
  }) {
    _validateKnownTool(tool);
    final normalizedSession = normalizeToolPolicySessionId(sessionId);
    final sessionPolicy = Map<String, ToolPolicyDecision>.from(
      sessions[normalizedSession] ?? const {},
    );
    sessionPolicy[tool] = decision;
    return ToolPolicyConfig(
      tools: tools,
      sessions: {
        ...sessions,
        normalizedSession: sessionPolicy,
      },
    );
  }

  int get explicitDecisionCount {
    return tools.length +
        sessions.values.fold<int>(0, (count, policy) => count + policy.length);
  }
}

class ProviderConfig {
  ProviderConfig({
    this.kind = 'openai-compatible',
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4.1-mini',
    this.apiKey,
    this.apiKeyEnv = 'OPENAI_API_KEY',
    this.timeoutSeconds = 60,
    this.maxRetries = 2,
    this.retryBackoffMs = 500,
  });

  final String kind;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String apiKeyEnv;
  final int timeoutSeconds;
  final int maxRetries;
  final int retryBackoffMs;

  factory ProviderConfig.fromJson(Map<String, Object?> json) {
    return ProviderConfig(
      kind: _stringAt(json, 'kind') ?? 'openai-compatible',
      baseUrl: _stringAt(json, 'baseUrl') ?? 'https://api.openai.com/v1',
      model: _stringAt(json, 'model') ?? 'gpt-4.1-mini',
      apiKey: _stringAt(json, 'apiKey'),
      apiKeyEnv: _stringAt(json, 'apiKeyEnv') ?? 'OPENAI_API_KEY',
      timeoutSeconds: _intAt(json, 'timeoutSeconds') ?? 60,
      maxRetries: _intAt(json, 'maxRetries') ?? 2,
      retryBackoffMs: _intAt(json, 'retryBackoffMs') ?? 500,
    );
  }

  Map<String, Object?> toJson() => {
        'kind': kind,
        'baseUrl': baseUrl,
        'model': model,
        if (apiKey != null && apiKey!.isNotEmpty) 'apiKey': apiKey,
        'apiKeyEnv': apiKeyEnv,
        'timeoutSeconds': timeoutSeconds,
        'maxRetries': maxRetries,
        'retryBackoffMs': retryBackoffMs,
      };

  ProviderConfig copyWith({
    String? kind,
    String? baseUrl,
    String? model,
    String? apiKey,
    String? apiKeyEnv,
    int? timeoutSeconds,
    int? maxRetries,
    int? retryBackoffMs,
  }) {
    return ProviderConfig(
      kind: kind ?? this.kind,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      maxRetries: maxRetries ?? this.maxRetries,
      retryBackoffMs: retryBackoffMs ?? this.retryBackoffMs,
    );
  }
}

class GatewayConfig {
  GatewayConfig({
    this.host = '127.0.0.1',
    this.port = 18987,
  });

  final String host;
  final int port;

  factory GatewayConfig.fromJson(Map<String, Object?> json) {
    return GatewayConfig(
      host: _stringAt(json, 'host') ?? '127.0.0.1',
      port: _intAt(json, 'port') ?? 18987,
    );
  }

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
      };

  GatewayConfig copyWith({
    String? host,
    int? port,
  }) {
    return GatewayConfig(
      host: host ?? this.host,
      port: port ?? this.port,
    );
  }
}

Map<String, Object?> _mapAt(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is Map ? value.cast<String, Object?>() : <String, Object?>{};
}

Map<String, EnvironmentConfig> _environmentsFromJson(
    Map<String, Object?> json) {
  final environments = <String, EnvironmentConfig>{};
  for (final entry in json.entries) {
    final key = normalizeEnvironmentName(entry.key);
    if (key == null || entry.value is! Map) {
      continue;
    }
    environments[key] = EnvironmentConfig.fromJson(
        (entry.value as Map).cast<String, Object?>());
  }
  return environments;
}

Map<String, ToolPolicyDecision> _decisionsFromJson(
  Map<String, Object?> json,
) {
  final decisions = <String, ToolPolicyDecision>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (value is! String) {
      continue;
    }
    decisions[entry.key] = parseToolPolicyDecision(value);
  }
  return decisions;
}

Map<String, Map<String, ToolPolicyDecision>> _sessionDecisionsFromJson(
  Map<String, Object?> json,
) {
  final sessions = <String, Map<String, ToolPolicyDecision>>{};
  for (final entry in json.entries) {
    if (entry.value is! Map) {
      continue;
    }
    sessions[entry.key] = _decisionsFromJson(
      (entry.value as Map).cast<String, Object?>(),
    );
  }
  return sessions;
}

Map<String, String> _decisionsToJson(
  Map<String, ToolPolicyDecision> decisions,
) {
  return decisions.map((key, value) => MapEntry(key, value.name));
}

void _validateKnownTool(String tool) {
  if (!knownToolNames.contains(tool)) {
    throw ArgumentError('Unsupported tool: $tool');
  }
}

String? normalizeEnvironmentName(String? name) {
  final normalized = name?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty || normalized == 'default') {
    return null;
  }
  return normalized;
}

String? _stringAt(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is String ? value : null;
}

int? _intAt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}
