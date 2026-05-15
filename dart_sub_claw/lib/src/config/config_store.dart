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
    await file.writeAsString('${encoder.convert(config.toJson())}\n');
  }

  Future<AppConfig> ensureExists() async {
    final config = await load();
    if (!await file.exists()) {
      await save(config);
    }
    return config;
  }

  Future<Object?> getValue(String path) async {
    final json = (await load()).toJson();
    return _readPath(json, path);
  }

  Future<AppConfig> setValue(String path, String rawValue) async {
    final current = await load();
    final updated = _applySet(current, path, rawValue);
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

  AppConfig _applySet(AppConfig config, String path, String rawValue) {
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
}

Map<String, Object?> redactConfigForDisplay(AppConfig config) {
  final json = config.toJson();
  final provider =
      Map<String, Object?>.from(json['provider'] as Map<String, Object?>);
  if (provider.containsKey('apiKey')) {
    provider['apiKey'] = '<redacted>';
  }
  json['provider'] = provider;
  return json;
}
