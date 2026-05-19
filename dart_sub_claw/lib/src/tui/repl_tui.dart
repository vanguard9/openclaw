import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:dart_tui/dart_tui.dart';

import '../agent/cancellation.dart';
import '../agent/agent_service.dart';
import '../config/app_config.dart';
import '../config/config_store.dart';
import '../sessions/chat_message.dart';
import '../sessions/session_store.dart';
import '../tools/tool_runtime.dart';

const Object _copyUnset = Object();
const int _maxInputHistory = 100;

class ReplTui {
  ReplTui({
    ConfigStore? configStore,
    SessionStore? sessionStore,
    AgentService? agentService,
  })  : configStore = configStore ?? ConfigStore(),
        sessionStore = sessionStore ?? SessionStore(),
        _agentService = agentService;

  final ConfigStore configStore;
  final SessionStore sessionStore;
  final AgentService? _agentService;

  Future<int> run({
    String sessionId = 'default',
    String? environment,
    int historyLimit = 12,
    bool captureMouse = false,
    bool altScreen = false,
  }) async {
    final config = await configStore.ensureExists();
    final envName = normalizeEnvironmentName(environment);
    final history = await sessionStore.read(sessionId);
    late final Program program;
    late final AgentService service;
    program = Program(
      programOptions: [
        if (altScreen) withAltScreen(),
        withHideCursor(false),
        withTickInterval(const Duration(milliseconds: 100)),
        if (captureMouse) withMouseCellMotion(),
        withoutSignalHandler(),
      ],
    );
    service = _agentService ??
        AgentService(
          configStore: configStore,
          sessionStore: sessionStore,
          toolRuntime: ToolRuntime(
            writableRoots: _defaultWritableRoots(),
            permissionHandler: (request) {
              final completer = Completer<ToolPermissionDecision>();
              program.send(_ToolPermissionPromptMsg(request, completer));
              return completer.future;
            },
          ),
        );
    await program.run(
      _ChatTuiModel(
        config: config,
        sessionStore: sessionStore,
        agentService: service,
        sessionId: sessionId,
        environment: envName,
        historyLimit: historyLimit,
        messages: _linesFromHistory(history, historyLimit),
        inputHistory: _inputHistoryFromMessages(history),
        send: program.send,
      ),
    );
    return 0;
  }
}

final class _ChatTuiModel extends TeaModel {
  _ChatTuiModel({
    required this.config,
    required this.sessionStore,
    required this.agentService,
    required this.sessionId,
    required this.environment,
    required this.historyLimit,
    required this.messages,
    required this.inputHistory,
    required this.send,
    TextInputModel? input,
    SpinnerModel? spinner,
    this.thinking = false,
    this.activeAssistantText = '',
    this.notice,
    this.width = 100,
    this.height = 30,
    this.inputHistoryIndex,
    this.draftInput = '',
    this.ignoredUnknownSequenceChars = 0,
    this.scrollOffset = 0,
    this.activeCancellation,
    this.pendingToolPermission,
    this.lastCtrlCAt,
  })  : input = input ??
            TextInputModel(
              placeholder: '输入消息或 /help',
              charLimit: 4000,
            ),
        spinner = spinner ??
            SpinnerModel(
              prefix: '思考中 ',
            );

  final AppConfig config;
  final SessionStore sessionStore;
  final AgentService agentService;
  final String sessionId;
  final String? environment;
  final int historyLimit;
  final List<_ChatLine> messages;
  final List<String> inputHistory;
  final void Function(Msg msg) send;
  final TextInputModel input;
  final SpinnerModel spinner;
  final bool thinking;
  final String activeAssistantText;
  final String? notice;
  final int width;
  final int height;
  final int? inputHistoryIndex;
  final String draftInput;
  final int ignoredUnknownSequenceChars;
  final int scrollOffset;
  final CancellationController? activeCancellation;
  final _PendingToolPermission? pendingToolPermission;
  final int? lastCtrlCAt;

  _ChatTuiModel copyWith({
    String? sessionId,
    String? environment,
    bool clearEnvironment = false,
    List<_ChatLine>? messages,
    List<String>? inputHistory,
    TextInputModel? input,
    SpinnerModel? spinner,
    bool? thinking,
    String? activeAssistantText,
    String? notice,
    bool clearNotice = false,
    int? width,
    int? height,
    Object? inputHistoryIndex = _copyUnset,
    String? draftInput,
    int? ignoredUnknownSequenceChars,
    int? scrollOffset,
    Object? activeCancellation = _copyUnset,
    Object? pendingToolPermission = _copyUnset,
    int? lastCtrlCAt,
  }) {
    return _ChatTuiModel(
      config: config,
      sessionStore: sessionStore,
      agentService: agentService,
      sessionId: sessionId ?? this.sessionId,
      environment: clearEnvironment ? null : environment ?? this.environment,
      historyLimit: historyLimit,
      messages: messages ?? this.messages,
      inputHistory: inputHistory ?? this.inputHistory,
      send: send,
      input: input ?? this.input,
      spinner: spinner ?? this.spinner,
      thinking: thinking ?? this.thinking,
      activeAssistantText: activeAssistantText ?? this.activeAssistantText,
      notice: clearNotice ? null : notice ?? this.notice,
      width: width ?? this.width,
      height: height ?? this.height,
      inputHistoryIndex: identical(inputHistoryIndex, _copyUnset)
          ? this.inputHistoryIndex
          : inputHistoryIndex as int?,
      draftInput: draftInput ?? this.draftInput,
      ignoredUnknownSequenceChars:
          ignoredUnknownSequenceChars ?? this.ignoredUnknownSequenceChars,
      scrollOffset: scrollOffset ?? this.scrollOffset,
      activeCancellation: identical(activeCancellation, _copyUnset)
          ? this.activeCancellation
          : activeCancellation as CancellationController?,
      pendingToolPermission: identical(pendingToolPermission, _copyUnset)
          ? this.pendingToolPermission
          : pendingToolPermission as _PendingToolPermission?,
      lastCtrlCAt: lastCtrlCAt ?? this.lastCtrlCAt,
    );
  }

  @override
  Cmd? init() => () => requestWindowSize();

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is TickMsg && thinking) {
      final (nextSpinner, cmd) = spinner.update(msg);
      return (copyWith(spinner: nextSpinner as SpinnerModel), cmd);
    }

    if (msg is WindowSizeMsg) {
      return (
        copyWith(
          width: msg.width > 20 ? msg.width : width,
          height: msg.height > 10 ? msg.height : height,
        ),
        null,
      );
    }

    if (msg is _AgentDeltaMsg) {
      return (
        copyWith(activeAssistantText: activeAssistantText + msg.delta),
        null,
      );
    }

    if (msg is _AgentCompleteMsg) {
      final nextMessages = [
        ...messages,
        _ChatLine.assistant(msg.reply),
      ];
      return (
        copyWith(
          messages: _trimLines(nextMessages, historyLimit),
          thinking: false,
          activeAssistantText: '',
          clearNotice: true,
          scrollOffset: 0,
          activeCancellation: null,
          pendingToolPermission: null,
        ),
        null,
      );
    }

    if (msg is _AgentCancelledMsg) {
      return (
        copyWith(
          thinking: false,
          activeAssistantText: '',
          notice: 'run cancelled',
          activeCancellation: null,
          pendingToolPermission: null,
        ),
        null,
      );
    }

    if (msg is _AgentErrorMsg) {
      return (
        copyWith(
          thinking: false,
          activeAssistantText: '',
          notice: 'error: ${msg.message}',
          activeCancellation: null,
          pendingToolPermission: null,
        ),
        null,
      );
    }

    if (msg is _ToolPermissionPromptMsg) {
      return (
        copyWith(
          pendingToolPermission:
              _PendingToolPermission(msg.request, msg.completer),
          activeAssistantText: '',
          clearNotice: true,
        ),
        null,
      );
    }

    if (msg is _HistoryLoadedMsg) {
      return (
        copyWith(
          sessionId: msg.sessionId,
          messages: _linesFromHistory(msg.messages, historyLimit),
          inputHistory: _inputHistoryFromMessages(msg.messages),
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
          input: input.copyWith(value: '', cursorPos: 0),
          notice: 'session switched to ${msg.sessionId}',
          scrollOffset: 0,
        ),
        null,
      );
    }

    if (msg is MouseWheelMsg) {
      final delta = msg.mouse.button == MouseButton.wheelUp
          ? _scrollPageSize
          : msg.mouse.button == MouseButton.wheelDown
              ? -_scrollPageSize
              : 0;
      if (delta == 0) {
        return (this, null);
      }
      return (copyWith(scrollOffset: _nextScrollOffset(delta)), null);
    }

    if (msg is MouseMsg) {
      return (this, null);
    }

    if (msg is KeyMsg) {
      if (pendingToolPermission != null) {
        return _handleToolPermissionKey(msg);
      }
      if (msg.key == 'ctrl+c') {
        return _handleCtrlC();
      }
      if (msg.key == 'esc') {
        return _handleEscape();
      }
      if (msg.key == 'pgup' || msg.key == 'ctrl+u') {
        return (
          copyWith(scrollOffset: _nextScrollOffset(_scrollPageSize)),
          null
        );
      }
      if (msg.key == 'pgdown' || msg.key == 'ctrl+d') {
        return (
          copyWith(scrollOffset: _nextScrollOffset(-_scrollPageSize)),
          null
        );
      }
      if (msg.key == 'ctrl+g') {
        return (copyWith(scrollOffset: 0), null);
      }
      if (msg.key == 'unknown') {
        return (copyWith(ignoredUnknownSequenceChars: 3), null);
      }
      final suppressed = _dropIgnoredUnknownSequenceChars(msg);
      if (suppressed != null) {
        return (suppressed, null);
      }
      if (msg.key == 'up') {
        return (_showPreviousInputHistory(), null);
      }
      if (msg.key == 'down') {
        return (_showNextInputHistory(), null);
      }

      final compositeActions = _actionsFromCompositeKey(msg);
      if (compositeActions != null) {
        return _handleInputActions(compositeActions);
      }

      if (msg.key == 'enter') {
        return _submitInput(input);
      }

      return (
        copyWith(
          input: _updateInput(input, msg),
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
        ),
        null,
      );
    }

    if (msg is PasteMsg && !thinking) {
      final pasted = msg.content.replaceAll(RegExp(r'[\r\n]+'), ' ');
      return (
        copyWith(
          input: _insertText(input, pasted),
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
        ),
        null,
      );
    }

    return (this, null);
  }

  (Model, Cmd?) _handleCtrlC() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (input.value.isNotEmpty) {
      return (
        copyWith(
          input: input.copyWith(value: '', cursorPos: 0),
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
          notice: 'cleared input; press ctrl+c again to exit',
          lastCtrlCAt: now,
        ),
        null,
      );
    }

    if (lastCtrlCAt != null && now - lastCtrlCAt! <= 1000) {
      return (this, _quitCommand(0));
    }

    return (
      copyWith(
        notice: 'press ctrl+c again to exit',
        lastCtrlCAt: now,
      ),
      null,
    );
  }

  (Model, Cmd?) _handleEscape() {
    if (pendingToolPermission != null) {
      return _resolveToolPermission(ToolPermissionDecision.deny);
    }
    if (thinking && activeCancellation != null) {
      activeCancellation!.cancel();
      return (copyWith(notice: 'cancelling run...'), null);
    }
    return (copyWith(clearNotice: true), null);
  }

  (Model, Cmd?) _handleToolPermissionKey(KeyMsg msg) {
    final text = msg.keyEvent.text.toLowerCase();
    final key = msg.key.toLowerCase();
    if (key == 'y' || text == 'y') {
      return _resolveToolPermission(ToolPermissionDecision.allow);
    }
    if (key == 'n' || key == 'esc' || text == 'n') {
      return _resolveToolPermission(ToolPermissionDecision.deny);
    }
    return (
      copyWith(notice: 'press y to allow or n to deny the tool request'),
      null,
    );
  }

  (Model, Cmd?) _resolveToolPermission(ToolPermissionDecision decision) {
    final pending = pendingToolPermission;
    if (pending == null) {
      return (this, null);
    }
    if (!pending.completer.isCompleted) {
      pending.completer.complete(decision);
    }
    return (
      copyWith(
        pendingToolPermission: null,
        notice: decision == ToolPermissionDecision.allow
            ? 'allowed tool ${pending.request.tool}'
            : 'denied tool ${pending.request.tool}',
      ),
      null,
    );
  }

  (Model, Cmd?) _handleInputActions(List<_InputAction> actions) {
    var nextInput = input;
    for (final action in actions) {
      switch (action.kind) {
        case _InputActionKind.insert:
          nextInput = _insertText(nextInput, action.text);
        case _InputActionKind.backspace:
          nextInput = _deleteBeforeCursor(nextInput);
        case _InputActionKind.enter:
          return copyWith(input: nextInput)._submitInput(nextInput);
      }
    }
    return (
      copyWith(
        input: nextInput,
        inputHistoryIndex: null,
        draftInput: '',
        ignoredUnknownSequenceChars: 0,
      ),
      null,
    );
  }

  (Model, Cmd?) _submitInput(TextInputModel sourceInput) {
    final value = sourceInput.value.trim();
    if (value.isEmpty) {
      return (copyWith(input: sourceInput), null);
    }
    final nextInputHistory = _rememberInput(inputHistory, value);
    if (value.startsWith('/')) {
      return copyWith(
        inputHistory: nextInputHistory,
        inputHistoryIndex: null,
        draftInput: '',
        ignoredUnknownSequenceChars: 0,
        input: sourceInput,
      )._handleSlashCommand(value);
    }
    if (thinking) {
      return (
        copyWith(
          input: sourceInput,
          notice: 'assistant is still responding; use /cancel or Esc',
        ),
        null,
      );
    }
    final nextMessages = [
      ...messages,
      _ChatLine.user(value),
    ];
    final cancellation = CancellationController();
    return (
      copyWith(
        messages: _trimLines(nextMessages, historyLimit),
        inputHistory: nextInputHistory,
        inputHistoryIndex: null,
        draftInput: '',
        ignoredUnknownSequenceChars: 0,
        scrollOffset: 0,
        input: sourceInput.copyWith(value: '', cursorPos: 0),
        thinking: true,
        activeAssistantText: '',
        activeCancellation: cancellation,
        clearNotice: true,
      ),
      _runAgentCommand(value, cancellation),
    );
  }

  _ChatTuiModel _showPreviousInputHistory() {
    if (inputHistory.isEmpty) {
      return this;
    }
    final nextIndex = inputHistoryIndex == null
        ? inputHistory.length - 1
        : (inputHistoryIndex! <= 0 ? 0 : inputHistoryIndex! - 1);
    final nextDraft = inputHistoryIndex == null ? input.value : draftInput;
    return copyWith(
      input: _inputWithValue(input, inputHistory[nextIndex]),
      inputHistoryIndex: nextIndex,
      draftInput: nextDraft,
      ignoredUnknownSequenceChars: 0,
    );
  }

  int get _scrollPageSize => (height ~/ 2).clamp(3, 20);

  int _nextScrollOffset(int delta) {
    return (scrollOffset + delta).clamp(0, _maxScrollOffset).toInt();
  }

  int get _maxScrollOffset {
    final contentWidth = (width - 2).clamp(40, 200);
    final maxBodyLines =
        _maxBodyLinesForHeight(height, notice, thinking, activeAssistantText);
    final bodyLineCount = _buildBodyLines(contentWidth).length;
    return (bodyLineCount - maxBodyLines).clamp(0, 1000000).toInt();
  }

  _ChatTuiModel _showNextInputHistory() {
    final index = inputHistoryIndex;
    if (index == null) {
      return this;
    }
    if (index >= inputHistory.length - 1) {
      return copyWith(
        input: _inputWithValue(input, draftInput),
        inputHistoryIndex: null,
        draftInput: '',
        ignoredUnknownSequenceChars: 0,
      );
    }
    final nextIndex = index + 1;
    return copyWith(
      input: _inputWithValue(input, inputHistory[nextIndex]),
      inputHistoryIndex: nextIndex,
      ignoredUnknownSequenceChars: 0,
    );
  }

  _ChatTuiModel? _dropIgnoredUnknownSequenceChars(KeyMsg msg) {
    if (ignoredUnknownSequenceChars <= 0 ||
        msg.keyEvent.code != KeyCode.rune ||
        msg.keyEvent.text.isEmpty) {
      return null;
    }

    final chars = msg.keyEvent.text.characters.toList();
    final remaining = ignoredUnknownSequenceChars - chars.length;
    if (remaining >= 0) {
      return copyWith(ignoredUnknownSequenceChars: remaining);
    }

    final text = chars.sublist(ignoredUnknownSequenceChars).join();
    return copyWith(
      input: _insertText(input, text),
      inputHistoryIndex: null,
      draftInput: '',
      ignoredUnknownSequenceChars: 0,
    );
  }

  (Model, Cmd?) _handleSlashCommand(String value) {
    final parts = value.split(RegExp(r'\s+'));
    final command = parts.first.toLowerCase();
    switch (command) {
      case '/cancel':
        if (thinking && activeCancellation != null) {
          activeCancellation!.cancel();
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              notice: 'cancelling run...',
            ),
            null,
          );
        }
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            notice: 'no active run',
          ),
          null,
        );
      case '/exit':
      case '/quit':
        return (this, _quitCommand(0));
      case '/help':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            notice:
                'commands: /help /status /history /session <id> /env <name|default> /clear /cancel /exit',
          ),
          null,
        );
      case '/status':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            notice: _statusLine(),
          ),
          null,
        );
      case '/history':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            notice: '${messages.length} visible message(s)',
          ),
          null,
        );
      case '/clear':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            messages: const [],
            activeAssistantText: '',
            notice: 'screen cleared; session history kept',
          ),
          null,
        );
      case '/session':
        if (parts.length < 2 || parts[1].trim().isEmpty) {
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              notice: 'usage: /session <id>',
            ),
            null,
          );
        }
        final nextSession = parts[1].trim();
        return (
          copyWith(input: input.copyWith(value: '', cursorPos: 0)),
          _loadSessionCommand(nextSession),
        );
      case '/env':
        if (parts.length < 2 || parts[1].trim().isEmpty) {
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              notice: 'usage: /env <name|default>',
            ),
            null,
          );
        }
        final nextEnv = normalizeEnvironmentName(parts[1]);
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            environment: nextEnv,
            clearEnvironment: nextEnv == null,
            notice: 'environment switched to ${nextEnv ?? 'default'}',
          ),
          null,
        );
      default:
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            notice: 'unknown command: $command',
          ),
          null,
        );
    }
  }

  Cmd _runAgentCommand(String value, CancellationController cancellation) {
    return () {
      unawaited(_runAgent(value, cancellation));
      return null;
    };
  }

  Future<void> _runAgent(
    String value,
    CancellationController cancellation,
  ) async {
    try {
      final result = await agentService.runTurnStreaming(
        message: value,
        sessionId: sessionId,
        environment: environment,
        cancellationToken: cancellation.token,
        onDelta: (delta) => send(_AgentDeltaMsg(delta)),
      );
      send(_AgentCompleteMsg(result.reply));
    } on CancelledException {
      send(_AgentCancelledMsg());
    } catch (error) {
      if (cancellation.isCancelled) {
        send(_AgentCancelledMsg());
        return;
      }
      send(_AgentErrorMsg('$error'));
    }
  }

  Cmd _loadSessionCommand(String nextSession) {
    return () async {
      try {
        final history = await sessionStore.read(nextSession);
        return _HistoryLoadedMsg(nextSession, history);
      } catch (error) {
        return _AgentErrorMsg('$error');
      }
    };
  }

  @override
  View view() {
    final envConfig = config.resolveEnvironment(environment);
    final contentWidth = (width - 2).clamp(40, 200);
    final lines = <String>[
      ..._wrapLine('dartsub tui', contentWidth),
      ..._wrapLine(
        'env=${environment ?? 'default'} model=${envConfig.provider.model} session=$sessionId',
        contentWidth,
      ),
      ..._wrapLine('baseUrl=${envConfig.provider.baseUrl}', contentWidth),
      ..._wrapLine(
        'commands: /help /status /history /session <id> /env <name|default> /clear /cancel /exit',
        contentWidth,
      ),
      '',
    ];

    final bodyLines = _buildBodyLines(contentWidth);
    final maxBodyLines =
        _maxBodyLinesForHeight(height, notice, thinking, activeAssistantText);
    final maxScrollOffset =
        (bodyLines.length - maxBodyLines).clamp(0, 1000000).toInt();
    final effectiveScrollOffset =
        scrollOffset.clamp(0, maxScrollOffset).toInt();
    final visibleEnd = bodyLines.length - effectiveScrollOffset;
    final visibleStart = (visibleEnd - maxBodyLines).clamp(0, bodyLines.length);
    lines.addAll(bodyLines.sublist(visibleStart, visibleEnd));

    lines.add('');
    if (pendingToolPermission != null) {
      lines.addAll(_wrapLine(
        _permissionPrompt(pendingToolPermission!.request),
        contentWidth,
      ));
    }
    if (thinking && activeAssistantText.isEmpty) {
      lines.add(spinner.view().content);
    }
    if (notice != null && notice!.isNotEmpty) {
      lines.addAll(_wrapLine('notice: $notice', contentWidth));
    }
    if (effectiveScrollOffset > 0) {
      lines.add('scroll: $effectiveScrollOffset line(s) above latest');
    }
    final inputView = _renderInput(input, contentWidth);
    lines.add(inputView.line);

    final view = newView(lines.join('\n'));
    view.cursor =
        Cursor(x: inputView.cursorX, y: lines.length - 1, blink: true);
    return view;
  }

  String _statusLine() {
    final envConfig = config.resolveEnvironment(environment);
    return 'env=${environment ?? 'default'} model=${envConfig.provider.model} session=$sessionId';
  }

  List<String> _buildBodyLines(int contentWidth) {
    final bodyLines = <String>[];
    if (messages.isEmpty && activeAssistantText.isEmpty) {
      bodyLines.add('history: empty');
      return bodyLines;
    }
    for (final message in messages) {
      bodyLines.addAll(
        _wrapLine('${message.label}> ${message.content}', contentWidth),
      );
    }
    if (activeAssistantText.isNotEmpty) {
      bodyLines
          .addAll(_wrapLine('assistant> $activeAssistantText', contentWidth));
    }
    return bodyLines;
  }
}

String _permissionPrompt(ToolPermissionRequest request) {
  final args = _oneLine(jsonEncode(request.arguments));
  return 'confirm: allow dangerous tool ${request.tool}? y/n args=$args';
}

List<Directory> _defaultWritableRoots() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    return const [];
  }
  return [Directory('$home${Platform.pathSeparator}Downloads')];
}

final class _InputRender {
  _InputRender({required this.line, required this.cursorX});

  final String line;
  final int cursorX;
}

enum _InputActionKind { insert, backspace, enter }

final class _InputAction {
  _InputAction.insert(this.text) : kind = _InputActionKind.insert;

  _InputAction.backspace()
      : kind = _InputActionKind.backspace,
        text = '';

  _InputAction.enter()
      : kind = _InputActionKind.enter,
        text = '';

  final _InputActionKind kind;
  final String text;
}

List<_InputAction>? _actionsFromCompositeKey(KeyMsg msg) {
  final key = msg.keyEvent;
  if (key.code != KeyCode.rune || key.text.isEmpty) {
    return null;
  }

  final chars = key.text.characters.toList();
  final isSimplePrintable =
      chars.length == 1 && _isPrintableCharacter(chars.single);
  if (isSimplePrintable) {
    return null;
  }

  final actions = <_InputAction>[];
  for (final char in chars) {
    if (char == '\r' || char == '\n') {
      actions.add(_InputAction.enter());
    } else if (char == '\b' || char == String.fromCharCode(0x7f)) {
      actions.add(_InputAction.backspace());
    } else if (_isPrintableCharacter(char)) {
      actions.add(_InputAction.insert(char));
    }
  }
  return actions;
}

TextInputModel _updateInput(TextInputModel input, KeyMsg msg) {
  return switch (msg.key) {
    'backspace' || 'ctrl+h' || 'alt+backspace' => _deleteBeforeCursor(input),
    'delete' => _deleteAtCursor(input),
    'left' => _moveCursor(input, -1),
    'right' => _moveCursor(input, 1),
    'home' => input.copyWith(cursorPos: 0),
    'end' => input.copyWith(
        cursorPos: _charactersOf(input.value).length,
      ),
    'tab' || 'enter' || 'esc' || 'up' || 'down' || 'unknown' => input,
    'space' => _insertText(input, ' '),
    _ => _insertPrintableKey(input, msg),
  };
}

TextInputModel _insertPrintableKey(TextInputModel input, KeyMsg msg) {
  final key = msg.keyEvent;
  if (key.code != KeyCode.rune) {
    return input;
  }
  if (key.modifiers.contains(KeyMod.ctrl) ||
      key.modifiers.contains(KeyMod.alt) ||
      key.modifiers.contains(KeyMod.meta)) {
    return input;
  }
  final text = key.text.isNotEmpty ? key.text : msg.key;
  return _insertText(input, text);
}

TextInputModel _insertText(TextInputModel input, String text) {
  final inserted = _printableCharacters(text);
  if (inserted.isEmpty || !input.focused) {
    return input;
  }

  final chars = _charactersOf(input.value);
  final cursor = _clampCursor(input.cursorPos, chars.length);
  final limit = input.charLimit;
  final allowed = limit <= 0 ? inserted.length : limit - chars.length;
  if (allowed <= 0) {
    return input;
  }

  final nextInserted =
      inserted.length > allowed ? inserted.take(allowed).toList() : inserted;
  final nextChars = List<String>.from(chars)..insertAll(cursor, nextInserted);
  return input.copyWith(
    value: nextChars.join(),
    cursorPos: cursor + nextInserted.length,
  );
}

TextInputModel _deleteBeforeCursor(TextInputModel input) {
  final chars = _charactersOf(input.value);
  final cursor = _clampCursor(input.cursorPos, chars.length);
  if (cursor == 0) {
    return input.copyWith(cursorPos: cursor);
  }
  final nextChars = List<String>.from(chars)..removeAt(cursor - 1);
  return input.copyWith(value: nextChars.join(), cursorPos: cursor - 1);
}

TextInputModel _deleteAtCursor(TextInputModel input) {
  final chars = _charactersOf(input.value);
  final cursor = _clampCursor(input.cursorPos, chars.length);
  if (cursor >= chars.length) {
    return input.copyWith(cursorPos: cursor);
  }
  final nextChars = List<String>.from(chars)..removeAt(cursor);
  return input.copyWith(value: nextChars.join(), cursorPos: cursor);
}

TextInputModel _moveCursor(TextInputModel input, int delta) {
  final length = _charactersOf(input.value).length;
  return input.copyWith(
      cursorPos: _clampCursor(input.cursorPos + delta, length));
}

_InputRender _renderInput(TextInputModel input, int maxWidth) {
  const prompt = 'you> ';
  final promptWidth = _displayWidth(prompt);
  final availableWidth = (maxWidth - promptWidth).clamp(10, 180);
  if (input.value.isEmpty) {
    final placeholder = _takeDisplayWidth(input.placeholder, availableWidth);
    return _InputRender(line: '$prompt$placeholder', cursorX: promptWidth);
  }

  final chars = _charactersOf(input.value);
  final cursor = _clampCursor(input.cursorPos, chars.length);
  var start = 0;
  while (start < cursor &&
      _displayWidth(chars.sublist(start, cursor).join()) > availableWidth) {
    start += 1;
  }

  var end = cursor;
  while (end < chars.length &&
      _displayWidth(chars.sublist(start, end + 1).join()) <= availableWidth) {
    end += 1;
  }

  final visible = chars.sublist(start, end).join();
  final cursorX =
      promptWidth + _displayWidth(chars.sublist(start, cursor).join());
  return _InputRender(line: '$prompt$visible', cursorX: cursorX);
}

int _maxBodyLinesForHeight(
  int height,
  String? notice,
  bool thinking,
  String activeAssistantText,
) {
  final reservedLines = 8 +
      (notice == null ? 0 : 1) +
      (thinking && activeAssistantText.isEmpty ? 1 : 0);
  return (height - reservedLines).clamp(3, 200).toInt();
}

List<String> _wrapLine(String text, int maxWidth) {
  final width = maxWidth <= 0 ? 80 : maxWidth;
  final output = <String>[];
  for (final paragraph in text.split('\n')) {
    if (paragraph.isEmpty) {
      output.add('');
      continue;
    }
    var line = '';
    var lineWidth = 0;
    for (final char in paragraph.characters) {
      final charWidth = _charWidth(char);
      if (line.isNotEmpty && lineWidth + charWidth > width) {
        output.add(line);
        line = '';
        lineWidth = 0;
      }
      line += char;
      lineWidth += charWidth;
    }
    output.add(line);
  }
  return output.isEmpty ? [''] : output;
}

String _takeDisplayWidth(String text, int maxWidth) {
  var output = '';
  var width = 0;
  for (final char in text.characters) {
    final charWidth = _charWidth(char);
    if (width + charWidth > maxWidth) {
      break;
    }
    output += char;
    width += charWidth;
  }
  return output;
}

int _displayWidth(String text) {
  var width = 0;
  for (final char in text.characters) {
    width += _charWidth(char);
  }
  return width;
}

int _charWidth(String char) {
  if (char.isEmpty) {
    return 0;
  }
  final rune = char.runes.first;
  if (rune == 0) {
    return 0;
  }
  if (rune < 32 || (rune >= 0x7f && rune < 0xa0)) {
    return 0;
  }
  if ((rune >= 0x1100 && rune <= 0x115f) ||
      (rune >= 0x2329 && rune <= 0x232a) ||
      (rune >= 0x2e80 && rune <= 0xa4cf) ||
      (rune >= 0xac00 && rune <= 0xd7a3) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xfe10 && rune <= 0xfe19) ||
      (rune >= 0xfe30 && rune <= 0xfe6f) ||
      (rune >= 0xff00 && rune <= 0xff60) ||
      (rune >= 0xffe0 && rune <= 0xffe6) ||
      (rune >= 0x1f300 && rune <= 0x1faff)) {
    return 2;
  }
  return 1;
}

List<String> _charactersOf(String value) => value.characters.toList();

List<String> _printableCharacters(String value) {
  return [
    for (final char in value.characters)
      if (_isPrintableCharacter(char)) char,
  ];
}

bool _isPrintableCharacter(String char) {
  if (char.isEmpty) {
    return false;
  }
  for (final rune in char.runes) {
    if (rune < 32 || rune == 0x7f) {
      return false;
    }
  }
  return true;
}

int _clampCursor(int cursor, int length) => cursor.clamp(0, length).toInt();

Cmd _quitCommand(int code) {
  return () {
    Timer(const Duration(milliseconds: 150), () => exit(code));
    return quit();
  };
}

TextInputModel _inputWithValue(TextInputModel input, String value) {
  return input.copyWith(value: value, cursorPos: value.characters.length);
}

final class _ChatLine {
  _ChatLine(this.label, this.content);

  factory _ChatLine.user(String content) => _ChatLine('you', content);

  factory _ChatLine.assistant(String content) =>
      _ChatLine('assistant', content);

  final String label;
  final String content;
}

final class _AgentDeltaMsg extends Msg {
  _AgentDeltaMsg(this.delta);
  final String delta;
}

final class _AgentCompleteMsg extends Msg {
  _AgentCompleteMsg(this.reply);
  final String reply;
}

final class _AgentCancelledMsg extends Msg {}

final class _AgentErrorMsg extends Msg {
  _AgentErrorMsg(this.message);
  final String message;
}

final class _HistoryLoadedMsg extends Msg {
  _HistoryLoadedMsg(this.sessionId, this.messages);
  final String sessionId;
  final List<ChatMessage> messages;
}

final class _ToolPermissionPromptMsg extends Msg {
  _ToolPermissionPromptMsg(this.request, this.completer);

  final ToolPermissionRequest request;
  final Completer<ToolPermissionDecision> completer;
}

final class _PendingToolPermission {
  _PendingToolPermission(this.request, this.completer);

  final ToolPermissionRequest request;
  final Completer<ToolPermissionDecision> completer;
}

List<_ChatLine> _linesFromHistory(List<ChatMessage> history, int limit) {
  final visible = history.length > limit
      ? history.sublist(history.length - limit)
      : history;
  return [
    for (final message in visible)
      if (message.role == 'assistant')
        _ChatLine.assistant(_oneLine(message.content))
      else
        _ChatLine.user(_oneLine(message.content)),
  ];
}

List<String> _inputHistoryFromMessages(List<ChatMessage> history) {
  final inputs = <String>[];
  for (final message in history) {
    if (message.role != 'user') {
      continue;
    }
    final value = message.content.trim();
    if (value.isNotEmpty) {
      inputs.add(value);
    }
  }
  return inputs.length > _maxInputHistory
      ? inputs.sublist(inputs.length - _maxInputHistory)
      : inputs;
}

List<String> _rememberInput(List<String> history, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return history;
  }
  final next = <String>[
    ...history,
    if (history.isEmpty || history.last != trimmed) trimmed,
  ];
  return next.length > _maxInputHistory
      ? next.sublist(next.length - _maxInputHistory)
      : next;
}

List<_ChatLine> _trimLines(List<_ChatLine> lines, int limit) {
  if (limit <= 0 || lines.length <= limit) {
    return lines;
  }
  return lines.sublist(lines.length - limit);
}

String _oneLine(String content) {
  final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= 800) {
    return normalized;
  }
  return '${normalized.substring(0, 797)}...';
}
