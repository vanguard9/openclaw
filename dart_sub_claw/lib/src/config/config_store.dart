import 'dart:convert';
import 'dart:io';

import '../runtime/paths.dart';
import 'app_config.dart';

class ConfigStore {
  ConfigStore({Directory? home}) : home = home ?? resolveAppHome();

  final Directory home;

  File get file => File('${home.path}${Platform.pathSeparator}config.json');

  Future<AppConfig> load() async {
    if (!await file.exists()) {
      return AppConfig();
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw FormatException('Config must be a JSON object: ${file.path}');
    }
    return AppConfig.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> save(AppConfig config) async {
    await home.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString('${encoder.convert(config.toJson())}\n');
    await tempFile.rename(file.path);
  }

  Future<AppConfig> ensureExists() async {
    final config = await load();
    if (!await file.exists()) {
      await save(config);
    }
    return config;
  }

  Future<Object?> getValue(String path, {String? environment}) async {
    final json = (await load()).toJson();
    final envName = normalizeEnvironmentName(environment);
    if (envName != null) {
      return _readPath(json, 'environments.$envName.$path');
    }
    return _readPath(json, path);
  }

  Future<AppConfig> setValue(
    String path,
    String rawValue, {
    String? environment,
  }) async {
    final current = await load();
    final updated =
        _applySet(current, path, rawValue, environment: environment);
    await save(updated);
    return updated;
  }

  Object? _readPath(Map<String, Object?> root, String path) {
    Object? cursor = root;
    for (final part in path.split('.')) {
      if (cursor is! Map<String, Object?>) return null;
      cursor = cursor[part];
    }
    return cursor;
  }

  AppConfig _applySet(
    AppConfig config,
    String path,
    String rawValue, {
    String? environment,
  }) {
    final envName = normalizeEnvironmentName(environment);
    if (envName != null) {
      return config.upsertEnvironment(envName, (current) {
        final scoped =
            AppConfig(provider: current.provider, gateway: current.gateway);
        final updated = _applySet(scoped, path, rawValue);
        return EnvironmentConfig(
            provider: updated.provider, gateway: updated.gateway);
      });
    }

    switch (path) {
      case 'provider.kind':
        return config.copyWith(
            provider: config.provider.copyWith(kind: rawValue));
      case 'provider.baseUrl':
        return config.copyWith(
            provider: config.provider.copyWith(baseUrl: rawValue));
      case 'provider.model':
        return config.copyWith(
            provider: config.provider.copyWith(model: rawValue));
      case 'provider.apiKey':
        return config.copyWith(
            provider: config.provider.copyWith(apiKey: rawValue));
      case 'provider.apiKeyEnv':
        return config.copyWith(
            provider: config.provider.copyWith(apiKeyEnv: rawValue));
      case 'provider.timeoutSeconds':
        return config.copyWith(
          provider: config.provider.copyWith(
            timeoutSeconds: _parseNonNegativeInt(
              rawValue,
              path,
              min: 1,
            ),
          ),
        );
      case 'provider.maxRetries':
        return config.copyWith(
          provider: config.provider.copyWith(
            maxRetries: _parseNonNegativeInt(rawValue, path),
          ),
        );
      case 'provider.retryBackoffMs':
        return config.copyWith(
          provider: config.provider.copyWith(
            retryBackoffMs: _parseNonNegativeInt(rawValue, path),
          ),
        );
      case 'gateway.host':
        return config.copyWith(
            gateway: config.gateway.copyWith(host: rawValue));
      case 'gateway.port':
        final port = int.tryParse(rawValue);
        if (port == null || port <= 0 || port > 65535) {
          throw FormatException('gateway.port must be a valid TCP port.');
        }
        return config.copyWith(gateway: config.gateway.copyWith(port: port));
      default:
        throw ArgumentError('Unsupported config key: $path');
    }
  }

  int _parseNonNegativeInt(String rawValue, String path, {int min = 0}) {
    final value = int.tryParse(rawValue);
    if (value == null || value < min) {
      throw FormatException('$path must be an integer >= $min.');
    }
    return value;
  }
}

Map<String, Object?> redactConfigForDisplay(AppConfig config) {
  final json = config.toJson();
  json['provider'] = _redactProvider(json['provider']);
  final environments = json['environments'];
  if (environments is Map<String, Object?>) {
    json['environments'] = environments.map((key, value) {
      if (value is! Map<String, Object?>) {
        return MapEntry(key, value);
      }
      final env = Map<String, Object?>.from(value);
      env['provider'] = _redactProvider(env['provider']);
      return MapEntry(key, env);
    });
  }
  return json;
}

Object? _redactProvider(Object? value) {
  if (value is! Map<String, Object?>) {
    return value;
  }
  final provider = Map<String, Object?>.from(value);
  if (provider.containsKey('apiKey')) {
    provider['apiKey'] = '<redacted>';
  }
  return provider;
}
