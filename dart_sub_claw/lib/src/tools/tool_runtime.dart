import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tool_policy.dart';

const int defaultMaxToolSteps = 4;
const int defaultShellTimeoutSeconds = 30;
const int defaultToolOutputLimit = 12000;

enum ToolRisk { safeRead, dangerous }

enum ToolPermissionDecision { allow, deny }

class ToolPermissionRequest {
  ToolPermissionRequest({
    required this.tool,
    required this.risk,
    required this.arguments,
  });

  final String tool;
  final ToolRisk risk;
  final Map<String, Object?> arguments;
}

typedef ToolPermissionHandler = FutureOr<ToolPermissionDecision> Function(
  ToolPermissionRequest request,
);

class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.risk,
    required this.parameters,
  });

  final String name;
  final String description;
  final ToolRisk risk;
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'risk': risk.name,
        'parameters': parameters,
      };
}

class ToolCall {
  ToolCall({
    required this.tool,
    required this.arguments,
  });

  final String tool;
  final Map<String, Object?> arguments;
}

class ToolResult {
  ToolResult({
    required this.tool,
    required this.ok,
    required this.output,
    this.exitCode,
    this.code,
  });

  final String tool;
  final bool ok;
  final String output;
  final int? exitCode;
  final String? code;

  Map<String, Object?> toJson() => {
        'tool': tool,
        'ok': ok,
        'output': output,
        if (exitCode != null) 'exitCode': exitCode,
        if (code != null) 'code': code,
      };
}

class ToolRuntime {
  ToolRuntime({
    Directory? root,
    List<Directory>? writableRoots,
    this.shellTimeoutSeconds = defaultShellTimeoutSeconds,
    this.outputLimit = defaultToolOutputLimit,
    this.requirePermissionForSafeRead = false,
    this.permissionHandler,
  })  : root = root ?? Directory.current,
        writableRoots = writableRoots ?? const [];

  final Directory root;
  final List<Directory> writableRoots;
  final int shellTimeoutSeconds;
  final int outputLimit;
  final bool requirePermissionForSafeRead;
  final ToolPermissionHandler? permissionHandler;

  List<ToolDefinition> get definitions => const [
        ToolDefinition(
          name: 'read_file',
          description:
              'Read a UTF-8 text file under the current working directory.',
          risk: ToolRisk.safeRead,
          parameters: {
            'type': 'object',
            'required': ['path'],
            'properties': {
              'path': {'type': 'string'},
            },
          },
        ),
        ToolDefinition(
          name: 'write_file',
          description:
              'Write UTF-8 text to a file under the current working directory. Requires permission.',
          risk: ToolRisk.dangerous,
          parameters: {
            'type': 'object',
            'required': ['path', 'content'],
            'properties': {
              'path': {'type': 'string'},
              'content': {'type': 'string'},
            },
          },
        ),
        ToolDefinition(
          name: 'shell',
          description:
              'Run a non-interactive shell command in the current working directory. Requires permission.',
          risk: ToolRisk.dangerous,
          parameters: {
            'type': 'object',
            'required': ['command'],
            'properties': {
              'command': {'type': 'string'},
            },
          },
        ),
      ];

  String get systemPrompt => '''
You may use tools when needed. Available tools are:
${const JsonEncoder.withIndent('  ').convert(definitions.map((tool) => tool.toJson()).toList())}

To call a tool, reply with only this XML-like wrapper and a JSON object inside it:
<tool_call>{"tool":"read_file","arguments":{"path":"README.md"}}</tool_call>

Do not include any other text before or after the tool_call wrapper. Use at most one tool per response. read_file is safe by default. write_file and shell require user permission and may be denied. After a tool result is provided, continue with the final answer or request another tool if necessary.
''';

  ToolCall? parseToolCall(String content) {
    final trimmed = content.trim();
    const start = '<tool_call>';
    const end = '</tool_call>';
    final startIndex = trimmed.indexOf(start);
    if (startIndex < 0) {
      return null;
    }
    var raw = trimmed.substring(startIndex + start.length);
    final endIndex = raw.indexOf(end);
    if (endIndex >= 0) {
      raw = raw.substring(0, endIndex);
    }
    final jsonStart = raw.indexOf('{');
    if (jsonStart < 0) {
      throw FormatException('tool call must include a JSON object');
    }
    final prefixTool = raw.substring(0, jsonStart).trim();
    final rawJson = _extractJsonObject(raw.substring(jsonStart));
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw FormatException('tool call must be a JSON object');
    }
    final json = decoded.cast<String, Object?>();
    final tool = json['tool'] ?? prefixTool;
    final args = json['arguments'];
    if (tool is! String || tool.trim().isEmpty) {
      throw FormatException('tool call requires a string tool name');
    }
    if (args is! Map) {
      throw FormatException('tool call requires an arguments object');
    }
    return ToolCall(
      tool: tool.trim(),
      arguments: args.cast<String, Object?>(),
    );
  }

  Future<ToolResult> run(
    ToolCall call, {
    ToolPermissionPolicy? policy,
    String? sessionId,
  }) async {
    try {
      final risk = _riskFor(call.tool);
      if (risk == null) {
        return ToolResult(
          tool: call.tool,
          ok: false,
          output: 'unknown tool: ${call.tool}',
          code: 'unknown_tool',
        );
      }
      final permission = await _permissionFor(
        call,
        risk,
        policy ?? ToolPermissionPolicy.empty,
        sessionId,
      );
      if (permission != ToolPermissionDecision.allow) {
        return ToolResult(
          tool: call.tool,
          ok: false,
          output:
              'permission denied for ${call.tool}; dangerous tools require explicit approval',
          code: 'permission_denied',
        );
      }
      return switch (call.tool) {
        'read_file' => await _readFile(call),
        'write_file' => await _writeFile(call),
        'shell' => await _shell(call),
        _ => throw StateError('unreachable tool dispatch: ${call.tool}'),
      };
    } catch (error) {
      return ToolResult(tool: call.tool, ok: false, output: '$error');
    }
  }

  ToolRisk? _riskFor(String tool) {
    return switch (tool) {
      'read_file' => ToolRisk.safeRead,
      'write_file' || 'shell' => ToolRisk.dangerous,
      _ => null,
    };
  }

  Future<ToolPermissionDecision> _permissionFor(
    ToolCall call,
    ToolRisk risk,
    ToolPermissionPolicy policy,
    String? sessionId,
  ) async {
    final policyDecision = policy.decisionFor(
      tool: call.tool,
      sessionId: sessionId,
    );
    if (policyDecision == ToolPolicyDecision.allow) {
      return ToolPermissionDecision.allow;
    }
    if (policyDecision == ToolPolicyDecision.deny) {
      return ToolPermissionDecision.deny;
    }
    if (risk == ToolRisk.safeRead && !requirePermissionForSafeRead) {
      return ToolPermissionDecision.allow;
    }
    final handler = permissionHandler;
    if (handler == null) {
      return ToolPermissionDecision.deny;
    }
    return handler(ToolPermissionRequest(
      tool: call.tool,
      risk: risk,
      arguments: call.arguments,
    ));
  }

  Future<ToolResult> _readFile(ToolCall call) async {
    final path = _stringArg(call, 'path');
    final file = File(_resolvePath(path));
    final content = await file.readAsString();
    return ToolResult(
      tool: call.tool,
      ok: true,
      output: _limit(content),
    );
  }

  Future<ToolResult> _writeFile(ToolCall call) async {
    final path = _stringArg(call, 'path');
    final content = _stringArg(call, 'content');
    final file = File(_resolvePath(path, extraRoots: writableRoots));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return ToolResult(
      tool: call.tool,
      ok: true,
      output: 'wrote ${content.length} character(s) to $path',
    );
  }

  Future<ToolResult> _shell(ToolCall call) async {
    final command = _stringArg(call, 'command').trim();
    if (command.isEmpty) {
      throw ArgumentError('command must not be empty');
    }
    final executable = Platform.isWindows ? 'cmd' : '/bin/sh';
    final args = Platform.isWindows ? ['/c', command] : ['-c', command];
    final process = await Process.start(
      executable,
      args,
      workingDirectory: root.absolute.path,
      runInShell: false,
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode.timeout(
      Duration(seconds: shellTimeoutSeconds < 1 ? 1 : shellTimeoutSeconds),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw TimeoutException(
          'shell command timed out after $shellTimeoutSeconds second(s)',
        );
      },
    );
    final stdoutText = await stdoutFuture;
    final stderrText = await stderrFuture;
    final output = [
      if (stdoutText.isNotEmpty) 'stdout:\n$stdoutText',
      if (stderrText.isNotEmpty) 'stderr:\n$stderrText',
      if (stdoutText.isEmpty && stderrText.isEmpty) '(no output)',
    ].join('\n');
    return ToolResult(
      tool: call.tool,
      ok: exitCode == 0,
      output: _limit(output),
      exitCode: exitCode,
    );
  }

  String _stringArg(ToolCall call, String name) {
    final value = call.arguments[name];
    if (value is! String) {
      throw ArgumentError('${call.tool} requires string argument "$name"');
    }
    return value;
  }

  String _resolvePath(String path, {List<Directory> extraRoots = const []}) {
    final rootUri = root.absolute.uri;
    final targetUri = rootUri.resolve(path);
    final targetPath = targetUri.toFilePath();
    if (targetUri.scheme != 'file') {
      throw ArgumentError('path escapes tool root: $path');
    }
    if (_isInsideDirectory(targetPath, rootUri.toFilePath())) {
      return targetPath;
    }
    for (final extraRoot in extraRoots) {
      if (_isInsideDirectory(targetPath, extraRoot.absolute.uri.toFilePath())) {
        return targetPath;
      }
    }
    throw ArgumentError('path escapes tool root: $path');
  }

  bool _isInsideDirectory(String targetPath, String rootPath) {
    return targetPath == rootPath ||
        targetPath.startsWith(rootPath.endsWith(Platform.pathSeparator)
            ? rootPath
            : '$rootPath${Platform.pathSeparator}');
  }

  String _limit(String value) {
    if (outputLimit <= 0 || value.length <= outputLimit) {
      return value;
    }
    return '${value.substring(0, outputLimit)}\n[truncated]';
  }
}

String _extractJsonObject(String value) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < value.length; i += 1) {
    final char = value[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
      continue;
    }
    if (char == '{') {
      depth += 1;
      continue;
    }
    if (char == '}') {
      depth -= 1;
      if (depth == 0) {
        return value.substring(0, i + 1);
      }
      if (depth < 0) {
        break;
      }
    }
  }
  throw FormatException('tool call JSON object is not complete');
}
