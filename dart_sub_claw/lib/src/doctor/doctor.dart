import 'dart:io';

import '../config/app_config.dart';
import '../config/config_store.dart';
import '../providers/openai_compatible_provider.dart';
import '../sessions/chat_message.dart';
import '../sessions/session_store.dart';

class DoctorOptions {
  DoctorOptions({
    this.environment,
    this.skipModel = false,
  });

  final String? environment;
  final bool skipModel;
}

class DoctorReport {
  DoctorReport(this.checks);

  final List<DoctorCheck> checks;

  bool get hasFailures =>
      checks.any((check) => check.status == DoctorStatus.fail);

  void writeTo(IOSink out) {
    for (final check in checks) {
      out.writeln('${check.status.label} ${check.name}: ${check.message}');
      if (check.detail != null && check.detail!.isNotEmpty) {
        out.writeln('    ${check.detail}');
      }
    }
  }
}

class DoctorCheck {
  DoctorCheck({
    required this.status,
    required this.name,
    required this.message,
    this.detail,
  });

  final DoctorStatus status;
  final String name;
  final String message;
  final String? detail;
}

enum DoctorStatus {
  ok('OK'),
  warn('WARN'),
  fail('FAIL');

  const DoctorStatus(this.label);

  final String label;
}

class DartSubDoctor {
  DartSubDoctor({
    ConfigStore? configStore,
    SessionStore? sessionStore,
  })  : configStore = configStore ?? ConfigStore(),
        sessionStore = sessionStore ?? SessionStore();

  final ConfigStore configStore;
  final SessionStore sessionStore;

  Future<DoctorReport> run(DoctorOptions options) async {
    final checks = <DoctorCheck>[];
    AppConfig? config;
    EnvironmentConfig? envConfig;
    final envName = normalizeEnvironmentName(options.environment);

    try {
      config = await configStore.ensureExists();
      envConfig = config.resolveEnvironment(envName);
      checks.add(DoctorCheck(
        status: DoctorStatus.ok,
        name: 'config',
        message: 'loaded ${configStore.file.path}',
      ));
    } catch (error) {
      checks.add(DoctorCheck(
        status: DoctorStatus.fail,
        name: 'config',
        message: 'failed to load config',
        detail: '$error',
      ));
      return DoctorReport(checks);
    }

    checks.add(_checkEnvironment(config, envName));
    checks.add(_checkProvider(envConfig.provider));
    checks.add(_checkApiKey(envConfig.provider));
    checks.add(await _checkGatewayPort(envConfig.gateway));
    checks.add(await _checkSessions());

    if (options.skipModel) {
      checks.add(DoctorCheck(
        status: DoctorStatus.warn,
        name: 'model',
        message: 'skipped model connectivity check',
      ));
    } else {
      checks.add(await _checkModel(envConfig.provider));
    }

    return DoctorReport(checks);
  }

  DoctorCheck _checkEnvironment(AppConfig config, String? envName) {
    if (envName == null) {
      return DoctorCheck(
        status: DoctorStatus.ok,
        name: 'environment',
        message: 'using default environment',
      );
    }
    if (!config.environments.containsKey(envName)) {
      return DoctorCheck(
        status: DoctorStatus.warn,
        name: 'environment',
        message:
            'environment "$envName" is not configured; falling back to default',
      );
    }
    return DoctorCheck(
      status: DoctorStatus.ok,
      name: 'environment',
      message: 'using "$envName"',
    );
  }

  DoctorCheck _checkProvider(ProviderConfig provider) {
    if (provider.kind != 'openai-compatible') {
      return DoctorCheck(
        status: DoctorStatus.fail,
        name: 'provider',
        message: 'unsupported provider kind ${provider.kind}',
      );
    }
    final baseUrl = Uri.tryParse(provider.baseUrl);
    if (baseUrl == null || !baseUrl.hasScheme || !baseUrl.hasAuthority) {
      return DoctorCheck(
        status: DoctorStatus.fail,
        name: 'provider',
        message: 'invalid provider.baseUrl',
        detail: provider.baseUrl,
      );
    }
    if (provider.model.trim().isEmpty) {
      return DoctorCheck(
        status: DoctorStatus.fail,
        name: 'provider',
        message: 'provider.model is empty',
      );
    }
    return DoctorCheck(
      status: DoctorStatus.ok,
      name: 'provider',
      message: '${provider.kind} ${provider.model}',
      detail: provider.baseUrl,
    );
  }

  DoctorCheck _checkApiKey(ProviderConfig provider) {
    if (provider.apiKey != null && provider.apiKey!.trim().isNotEmpty) {
      return DoctorCheck(
        status: DoctorStatus.ok,
        name: 'api key',
        message: 'configured directly in config',
      );
    }
    final envValue = Platform.environment[provider.apiKeyEnv];
    if (envValue != null && envValue.trim().isNotEmpty) {
      return DoctorCheck(
        status: DoctorStatus.ok,
        name: 'api key',
        message: 'found in ${provider.apiKeyEnv}',
      );
    }
    return DoctorCheck(
      status: DoctorStatus.fail,
      name: 'api key',
      message: 'missing API key',
      detail:
          'Set ${provider.apiKeyEnv} or run dartsub config set provider.apiKey <key>',
    );
  }

  Future<DoctorCheck> _checkGatewayPort(GatewayConfig gateway) async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(gateway.host, gateway.port);
      return DoctorCheck(
        status: DoctorStatus.ok,
        name: 'gateway port',
        message: '${gateway.host}:${gateway.port} is available',
      );
    } catch (error) {
      return DoctorCheck(
        status: DoctorStatus.warn,
        name: 'gateway port',
        message:
            '${gateway.host}:${gateway.port} is already in use or unavailable',
        detail: '$error',
      );
    } finally {
      await socket?.close();
    }
  }

  Future<DoctorCheck> _checkSessions() async {
    try {
      await sessionStore.sessionsDir.create(recursive: true);
      final ids = await sessionStore.listSessionIds();
      return DoctorCheck(
        status: DoctorStatus.ok,
        name: 'sessions',
        message: '${sessionStore.sessionsDir.path} (${ids.length} session(s))',
      );
    } catch (error) {
      return DoctorCheck(
        status: DoctorStatus.fail,
        name: 'sessions',
        message: 'session directory is not usable',
        detail: '$error',
      );
    }
  }

  Future<DoctorCheck> _checkModel(ProviderConfig provider) async {
    try {
      final reply = await OpenAiCompatibleProvider(provider).complete(
        messages: [ChatMessage(role: 'user', content: 'Reply with OK only.')],
      );
      final normalized = reply.trim();
      return DoctorCheck(
        status: DoctorStatus.ok,
        name: 'model',
        message: 'connectivity check succeeded',
        detail:
            normalized.length <= 80 ? normalized : normalized.substring(0, 80),
      );
    } catch (error) {
      return DoctorCheck(
        status: DoctorStatus.fail,
        name: 'model',
        message: 'connectivity check failed',
        detail: '$error',
      );
    }
  }
}
