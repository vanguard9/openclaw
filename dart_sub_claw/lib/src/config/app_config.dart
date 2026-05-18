class AppConfig {
  AppConfig({
    ProviderConfig? provider,
    GatewayConfig? gateway,
    Map<String, EnvironmentConfig>? environments,
  })  : provider = provider ?? ProviderConfig(),
        gateway = gateway ?? GatewayConfig(),
        environments = Map.unmodifiable(environments ?? const {});

  final ProviderConfig provider;
  final GatewayConfig gateway;
  final Map<String, EnvironmentConfig> environments;

  factory AppConfig.fromJson(Map<String, Object?> json) {
    return AppConfig(
      provider: ProviderConfig.fromJson(_mapAt(json, 'provider')),
      gateway: GatewayConfig.fromJson(_mapAt(json, 'gateway')),
      environments: _environmentsFromJson(_mapAt(json, 'environments')),
    );
  }

  Map<String, Object?> toJson() => {
        'provider': provider.toJson(),
        'gateway': gateway.toJson(),
        if (environments.isNotEmpty)
          'environments': environments.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
      };

  AppConfig copyWith({
    ProviderConfig? provider,
    GatewayConfig? gateway,
    Map<String, EnvironmentConfig>? environments,
  }) {
    return AppConfig(
      provider: provider ?? this.provider,
      gateway: gateway ?? this.gateway,
      environments: environments ?? this.environments,
    );
  }

  EnvironmentConfig resolveEnvironment(String? name) {
    final normalized = normalizeEnvironmentName(name);
    if (normalized == null) {
      return EnvironmentConfig(provider: provider, gateway: gateway);
    }
    return environments[normalized] ??
        EnvironmentConfig(provider: provider, gateway: gateway);
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
          EnvironmentConfig(provider: provider, gateway: gateway),
    );
    return copyWith(environments: next);
  }
}

class EnvironmentConfig {
  EnvironmentConfig({
    ProviderConfig? provider,
    GatewayConfig? gateway,
  })  : provider = provider ?? ProviderConfig(),
        gateway = gateway ?? GatewayConfig();

  final ProviderConfig provider;
  final GatewayConfig gateway;

  factory EnvironmentConfig.fromJson(Map<String, Object?> json) {
    return EnvironmentConfig(
      provider: ProviderConfig.fromJson(_mapAt(json, 'provider')),
      gateway: GatewayConfig.fromJson(_mapAt(json, 'gateway')),
    );
  }

  Map<String, Object?> toJson() => {
        'provider': provider.toJson(),
        'gateway': gateway.toJson(),
      };

  EnvironmentConfig copyWith({
    ProviderConfig? provider,
    GatewayConfig? gateway,
  }) {
    return EnvironmentConfig(
      provider: provider ?? this.provider,
      gateway: gateway ?? this.gateway,
    );
  }
}

class ProviderConfig {
  ProviderConfig({
    this.kind = 'openai-compatible',
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4.1-mini',
    this.apiKey,
    this.apiKeyEnv = 'OPENAI_API_KEY',
  });

  final String kind;
  final String baseUrl;
  final String model;
  final String? apiKey;
  final String apiKeyEnv;

  factory ProviderConfig.fromJson(Map<String, Object?> json) {
    return ProviderConfig(
      kind: _stringAt(json, 'kind') ?? 'openai-compatible',
      baseUrl: _stringAt(json, 'baseUrl') ?? 'https://api.openai.com/v1',
      model: _stringAt(json, 'model') ?? 'gpt-4.1-mini',
      apiKey: _stringAt(json, 'apiKey'),
      apiKeyEnv: _stringAt(json, 'apiKeyEnv') ?? 'OPENAI_API_KEY',
    );
  }

  Map<String, Object?> toJson() => {
        'kind': kind,
        'baseUrl': baseUrl,
        'model': model,
        if (apiKey != null && apiKey!.isNotEmpty) 'apiKey': apiKey,
        'apiKeyEnv': apiKeyEnv,
      };

  ProviderConfig copyWith({
    String? kind,
    String? baseUrl,
    String? model,
    String? apiKey,
    String? apiKeyEnv,
  }) {
    return ProviderConfig(
      kind: kind ?? this.kind,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
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
