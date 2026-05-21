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
import '../tools/tool_policy.dart';
import '../tools/tool_runtime.dart';
import 'tui_strings.dart';

const Object _copyUnset = Object();
const int _maxInputHistory = 100;
const String _inputPlaceholder = '';
const String _ansiReset = '\x1b[0m';
const String _userMessageStyle = '\x1b[48;2;49;50;68m\x1b[38;2;236;239;244m';
const String _toolMessageStyle = '\x1b[38;2;148;163;184m';
const String _noticeStyle = '\x1b[38;2;251;191;36m';

enum _ActivityState {
  idle('idle'),
  sending('sending'),
  waiting('waiting'),
  streaming('streaming'),
  permissionRequired('permission required'),
  cancelling('cancelling'),
  cancelled('cancelled'),
  error('error');

  const _ActivityState(this.label);

  final String label;

  bool get isActive => switch (this) {
        _ActivityState.sending ||
        _ActivityState.waiting ||
        _ActivityState.streaming ||
        _ActivityState.permissionRequired ||
        _ActivityState.cancelling =>
          true,
        _ => false,
      };
}

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
    TuiLocalePreference? localeOverride,
    bool captureMouse = false,
    bool altScreen = false,
  }) async {
    final config = await configStore.ensureExists();
    final envName = normalizeEnvironmentName(environment);
    final history = await sessionStore.read(sessionId);
    final knownSessionIds = await sessionStore.listSessionIds();
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
            requirePermissionForSafeRead: true,
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
        configStore: configStore,
        sessionStore: sessionStore,
        agentService: service,
        sessionId: sessionId,
        environment: envName,
        historyLimit: historyLimit,
        localePreference: localeOverride ?? config.tui.locale,
        knownSessionIds: {
          sessionId,
          ...knownSessionIds,
        }.toList(),
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
    required this.configStore,
    required this.sessionStore,
    required this.agentService,
    required this.sessionId,
    required this.environment,
    required this.historyLimit,
    required this.localePreference,
    required this.knownSessionIds,
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
    this.activity = _ActivityState.idle,
    this.activityStartedAt,
    this.placeholderSuppressed = false,
    this.showThinking = true,
    this.toolDetailsExpanded = false,
    Set<String>? sessionAllowedTools,
    this.activeCancellation,
    this.pendingToolPermission,
    this.lastCtrlCAt,
    this.slashSelectionIndex = 0,
    this.slashSuggestionsDismissed = false,
    this.helpPanelVisible = false,
  })  : input = input ??
            TextInputModel(
              placeholder: _inputPlaceholder,
              charLimit: 4000,
            ),
        spinner = spinner ??
            SpinnerModel(
              prefix: '思考中 ',
            ),
        sessionAllowedTools = Set.unmodifiable(sessionAllowedTools ?? const {});

  final AppConfig config;
  final ConfigStore configStore;
  final SessionStore sessionStore;
  final AgentService agentService;
  final String sessionId;
  final String? environment;
  final int historyLimit;
  final TuiLocalePreference localePreference;
  final List<String> knownSessionIds;
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
  final _ActivityState activity;
  final int? activityStartedAt;
  final bool placeholderSuppressed;
  final bool showThinking;
  final bool toolDetailsExpanded;
  final Set<String> sessionAllowedTools;
  final CancellationController? activeCancellation;
  final _PendingToolPermission? pendingToolPermission;
  final int? lastCtrlCAt;
  final int slashSelectionIndex;
  final bool slashSuggestionsDismissed;
  final bool helpPanelVisible;

  TuiStrings get strings => TuiStrings.resolve(localePreference);

  _ChatTuiModel copyWith({
    AppConfig? config,
    String? sessionId,
    String? environment,
    bool clearEnvironment = false,
    TuiLocalePreference? localePreference,
    List<String>? knownSessionIds,
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
    _ActivityState? activity,
    Object? activityStartedAt = _copyUnset,
    bool? placeholderSuppressed,
    bool? showThinking,
    bool? toolDetailsExpanded,
    Set<String>? sessionAllowedTools,
    Object? activeCancellation = _copyUnset,
    Object? pendingToolPermission = _copyUnset,
    int? lastCtrlCAt,
    int? slashSelectionIndex,
    bool? slashSuggestionsDismissed,
    bool? helpPanelVisible,
  }) {
    return _ChatTuiModel(
      config: config ?? this.config,
      configStore: configStore,
      sessionStore: sessionStore,
      agentService: agentService,
      sessionId: sessionId ?? this.sessionId,
      environment: clearEnvironment ? null : environment ?? this.environment,
      historyLimit: historyLimit,
      localePreference: localePreference ?? this.localePreference,
      knownSessionIds: knownSessionIds ?? this.knownSessionIds,
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
      activity: activity ?? this.activity,
      activityStartedAt: identical(activityStartedAt, _copyUnset)
          ? this.activityStartedAt
          : activityStartedAt as int?,
      placeholderSuppressed:
          placeholderSuppressed ?? this.placeholderSuppressed,
      showThinking: showThinking ?? this.showThinking,
      toolDetailsExpanded: toolDetailsExpanded ?? this.toolDetailsExpanded,
      sessionAllowedTools: sessionAllowedTools ?? this.sessionAllowedTools,
      activeCancellation: identical(activeCancellation, _copyUnset)
          ? this.activeCancellation
          : activeCancellation as CancellationController?,
      pendingToolPermission: identical(pendingToolPermission, _copyUnset)
          ? this.pendingToolPermission
          : pendingToolPermission as _PendingToolPermission?,
      lastCtrlCAt: lastCtrlCAt ?? this.lastCtrlCAt,
      slashSelectionIndex: slashSelectionIndex ?? this.slashSelectionIndex,
      slashSuggestionsDismissed:
          slashSuggestionsDismissed ?? this.slashSuggestionsDismissed,
      helpPanelVisible: helpPanelVisible ?? this.helpPanelVisible,
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

    if (msg is TickMsg && activity.isActive) {
      return (copyWith(), null);
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
        copyWith(
          activeAssistantText: activeAssistantText + msg.delta,
          activity: _ActivityState.streaming,
          activityStartedAt: _activityStartedAt(_ActivityState.streaming),
        ),
        null,
      );
    }

    if (msg is _AgentWaitingMsg) {
      return (
        copyWith(
          activity: _ActivityState.waiting,
          activityStartedAt: _activityStartedAt(_ActivityState.waiting),
        ),
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
          activity: _ActivityState.idle,
          activityStartedAt: null,
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
          activity: _ActivityState.cancelled,
          activityStartedAt: null,
          activeAssistantText: '',
          notice: strings.runCancelled,
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
          activity: _ActivityState.error,
          activityStartedAt: null,
          activeAssistantText: '',
          notice: strings.error(msg.message),
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
          activity: _ActivityState.permissionRequired,
          activityStartedAt:
              _activityStartedAt(_ActivityState.permissionRequired),
          activeAssistantText: '',
          clearNotice: true,
        ),
        null,
      );
    }

    if (msg is _ToolStartedMsg) {
      final nextMessages = [
        ...messages,
        _ChatLine.tool(_ToolEvent.running(msg.call)),
      ];
      return (
        copyWith(
          messages: _trimLines(nextMessages, historyLimit),
          activity: _ActivityState.waiting,
          activityStartedAt: _activityStartedAt(_ActivityState.waiting),
        ),
        null,
      );
    }

    if (msg is _ToolFinishedMsg) {
      final nextMessages = _completeRunningTool(messages, msg.result);
      return (
        copyWith(
          messages: _trimLines(nextMessages, historyLimit),
          activity: thinking ? _ActivityState.waiting : activity,
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
          placeholderSuppressed: false,
          notice: strings.sessionSwitched(msg.sessionId),
          scrollOffset: 0,
          knownSessionIds: {
            msg.sessionId,
            ...knownSessionIds,
          }.toList(),
          slashSelectionIndex: 0,
          slashSuggestionsDismissed: false,
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

    if (msg is MouseClickMsg) {
      return (
        copyWith(
          input: input.copyWith(focused: true),
          placeholderSuppressed: true,
        ),
        null,
      );
    }

    if (msg is MouseMsg) {
      return (this, null);
    }

    if (msg is KeyMsg) {
      if (msg.key == 'ctrl+c') {
        return _handleCtrlC();
      }
      if (msg.key == 'esc') {
        return _handleEscape();
      }
      if (msg.key == 'ctrl+d') {
        return input.value.isEmpty ? (this, _quitCommand(0)) : (this, null);
      }
      if (msg.key == 'ctrl+o') {
        return _toggleToolDetails();
      }
      if (msg.key == 'ctrl+t') {
        return _toggleThinkingDisplay();
      }
      if (pendingToolPermission != null) {
        return _handleToolPermissionKey(msg);
      }
      if (msg.key == 'pgup' || msg.key == 'ctrl+u') {
        return (
          copyWith(scrollOffset: _nextScrollOffset(_scrollPageSize)),
          null
        );
      }
      if (msg.key == 'pgdown') {
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
      final slashSuggestions = _slashSuggestions();
      if (slashSuggestions.isNotEmpty) {
        if (msg.key == 'up' && inputHistoryIndex == null) {
          return (_moveSlashSelection(-1, slashSuggestions), null);
        }
        if (msg.key == 'down' && inputHistoryIndex == null) {
          return (_moveSlashSelection(1, slashSuggestions), null);
        }
        if (msg.key == 'tab') {
          return (_acceptSlashSuggestion(slashSuggestions), null);
        }
        if (msg.key == 'enter') {
          return _submitOrAcceptSlashSuggestion(slashSuggestions);
        }
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
          input: _updateInput(input.copyWith(focused: true), msg),
          placeholderSuppressed: true,
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
          slashSelectionIndex: 0,
          slashSuggestionsDismissed: false,
          helpPanelVisible: false,
        ),
        null,
      );
    }

    if (msg is PasteMsg && !thinking) {
      final pasted = msg.content.replaceAll(RegExp(r'[\r\n]+'), ' ');
      return (
        copyWith(
          input: _insertText(input, pasted),
          placeholderSuppressed: true,
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
          slashSelectionIndex: 0,
          slashSuggestionsDismissed: false,
          helpPanelVisible: false,
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
          placeholderSuppressed: false,
          inputHistoryIndex: null,
          draftInput: '',
          ignoredUnknownSequenceChars: 0,
          notice: strings.clearedInput(),
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
        notice: strings.pressCtrlCToExit(),
        lastCtrlCAt: now,
      ),
      null,
    );
  }

  (Model, Cmd?) _handleEscape() {
    if (pendingToolPermission != null) {
      return _resolveToolPermission(ToolPermissionDecision.deny);
    }
    if (_slashSuggestions().isNotEmpty) {
      return (
        copyWith(
          slashSuggestionsDismissed: true,
          slashSelectionIndex: 0,
        ),
        null,
      );
    }
    if (helpPanelVisible) {
      return (copyWith(helpPanelVisible: false), null);
    }
    if (thinking && activeCancellation != null) {
      activeCancellation!.cancel();
      return (
        copyWith(
          activity: _ActivityState.cancelling,
          activityStartedAt: null,
          notice: strings.cancellingRun,
        ),
        null,
      );
    }
    return (copyWith(clearNotice: true), null);
  }

  (Model, Cmd?) _toggleToolDetails() {
    final next = !toolDetailsExpanded;
    return (
      copyWith(
        toolDetailsExpanded: next,
        notice: strings.toolDetails(next),
      ),
      null,
    );
  }

  (Model, Cmd?) _toggleThinkingDisplay() {
    final next = !showThinking;
    return (
      copyWith(
        showThinking: next,
        notice: strings.thinkingDisplay(next),
      ),
      null,
    );
  }

  (Model, Cmd?) _handleToolPermissionKey(KeyMsg msg) {
    final text = msg.keyEvent.text.toLowerCase();
    final key = msg.key.toLowerCase();
    if (key == 'y' || text == 'y') {
      return _resolveToolPermission(ToolPermissionDecision.allow);
    }
    if (key == 'a' || text == 'a') {
      return _resolveToolPermission(
        ToolPermissionDecision.allow,
        rememberForSession: true,
      );
    }
    if (key == 'n' || key == 'esc' || text == 'n') {
      return _resolveToolPermission(ToolPermissionDecision.deny);
    }
    return (
      copyWith(notice: strings.invalidPermissionChoice()),
      null,
    );
  }

  (Model, Cmd?) _resolveToolPermission(
    ToolPermissionDecision decision, {
    bool rememberForSession = false,
  }) {
    final pending = pendingToolPermission;
    if (pending == null) {
      return (this, null);
    }
    if (!pending.completer.isCompleted) {
      pending.completer.complete(decision);
    }
    final remember =
        rememberForSession && decision == ToolPermissionDecision.allow;
    final nextAllowedTools = remember
        ? {...sessionAllowedTools, pending.request.tool}
        : sessionAllowedTools;
    return (
      copyWith(
        pendingToolPermission: null,
        sessionAllowedTools: nextAllowedTools,
        activity: thinking ? _ActivityState.waiting : _ActivityState.idle,
        activityStartedAt:
            thinking ? _activityStartedAt(_ActivityState.waiting) : null,
        notice: remember
            ? strings.allowedTool(pending.request.tool, forSession: true)
            : decision == ToolPermissionDecision.allow
                ? strings.allowedTool(pending.request.tool, forSession: false)
                : strings.deniedTool(pending.request.tool),
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
        placeholderSuppressed: true,
        inputHistoryIndex: null,
        draftInput: '',
        ignoredUnknownSequenceChars: 0,
        slashSelectionIndex: 0,
        slashSuggestionsDismissed: false,
        helpPanelVisible: false,
      ),
      null,
    );
  }

  _ChatTuiModel _moveSlashSelection(
    int delta,
    List<_SlashSuggestion> suggestions,
  ) {
    final selected = _selectedSlashSuggestionIndex(suggestions);
    final next = (selected + delta).clamp(0, suggestions.length - 1).toInt();
    return copyWith(slashSelectionIndex: next);
  }

  _ChatTuiModel _acceptSlashSuggestion(List<_SlashSuggestion> suggestions) {
    final suggestion = suggestions[_selectedSlashSuggestionIndex(suggestions)];
    return copyWith(
      input: _inputWithValue(input, suggestion.completionValue),
      inputHistoryIndex: null,
      draftInput: '',
      ignoredUnknownSequenceChars: 0,
      placeholderSuppressed: true,
      slashSelectionIndex: 0,
      slashSuggestionsDismissed: false,
    );
  }

  (Model, Cmd?) _submitOrAcceptSlashSuggestion(
    List<_SlashSuggestion> suggestions,
  ) {
    final suggestion = suggestions[_selectedSlashSuggestionIndex(suggestions)];
    if (suggestion.executeOnEnter) {
      return _submitInput(_inputWithValue(input, suggestion.value));
    }
    final current = input.value.trim();
    if (current == suggestion.value && !suggestion.requiresArgument) {
      return _submitInput(input);
    }
    return (_acceptSlashSuggestion(suggestions), null);
  }

  int _selectedSlashSuggestionIndex(List<_SlashSuggestion> suggestions) {
    return slashSelectionIndex.clamp(0, suggestions.length - 1).toInt();
  }

  (Model, Cmd?) _submitInput(TextInputModel sourceInput) {
    final value = sourceInput.value.trim();
    if (value.isEmpty) {
      return (copyWith(input: sourceInput, placeholderSuppressed: true), null);
    }
    final nextInputHistory = _rememberInput(inputHistory, value);
    if (value.startsWith('/')) {
      return copyWith(
        inputHistory: nextInputHistory,
        inputHistoryIndex: null,
        draftInput: '',
        ignoredUnknownSequenceChars: 0,
        input: sourceInput,
        placeholderSuppressed: false,
        slashSelectionIndex: 0,
        slashSuggestionsDismissed: false,
      )._handleSlashCommand(value);
    }
    if (thinking) {
      return (
        copyWith(
          input: sourceInput,
          placeholderSuppressed: false,
          notice: strings.assistantBusy,
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
        placeholderSuppressed: false,
        thinking: true,
        activity: _ActivityState.sending,
        activityStartedAt: DateTime.now().millisecondsSinceEpoch,
        activeAssistantText: '',
        activeCancellation: cancellation,
        clearNotice: true,
        slashSelectionIndex: 0,
        slashSuggestionsDismissed: false,
        helpPanelVisible: false,
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
      placeholderSuppressed: true,
      ignoredUnknownSequenceChars: 0,
      slashSelectionIndex: 0,
      slashSuggestionsDismissed: false,
    );
  }

  int get _scrollPageSize => (height ~/ 2).clamp(3, 20);

  int _nextScrollOffset(int delta) {
    return (scrollOffset + delta).clamp(0, _maxScrollOffset).toInt();
  }

  int get _maxScrollOffset {
    final contentWidth = (width - 2).clamp(20, 200).toInt();
    final bodyLineCount = _buildBodyLines(contentWidth).length;
    final compactLayout = _isCompactLayout;
    final tightLayout = _isTightLayout;
    final headerLines = _buildHeaderLines(contentWidth, compact: compactLayout);
    final inputView = _footerInputView(contentWidth, compact: compactLayout);
    var footerLines = _buildFooterLines(
      contentWidth,
      inputView: inputView,
      compact: compactLayout,
      tight: tightLayout,
    );
    final bodyHeightWithoutScroll =
        _bodyViewportHeight(headerLines.length, footerLines.length);
    final showScrollStatus =
        bodyLineCount > bodyHeightWithoutScroll || scrollOffset > 0;
    if (showScrollStatus) {
      footerLines = _buildFooterLines(
        contentWidth,
        inputView: inputView,
        compact: compactLayout,
        tight: tightLayout,
        scrollText: strings.scrollLatest(),
      );
    }
    final bodyHeight =
        _bodyViewportHeight(headerLines.length, footerLines.length);
    return (bodyLineCount - bodyHeight).clamp(0, 1000000).toInt();
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
        placeholderSuppressed: false,
        ignoredUnknownSequenceChars: 0,
        slashSelectionIndex: 0,
        slashSuggestionsDismissed: false,
      );
    }
    final nextIndex = index + 1;
    return copyWith(
      input: _inputWithValue(input, inputHistory[nextIndex]),
      inputHistoryIndex: nextIndex,
      placeholderSuppressed: true,
      ignoredUnknownSequenceChars: 0,
      slashSelectionIndex: 0,
      slashSuggestionsDismissed: false,
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
      placeholderSuppressed: true,
      inputHistoryIndex: null,
      draftInput: '',
      ignoredUnknownSequenceChars: 0,
      slashSelectionIndex: 0,
      slashSuggestionsDismissed: false,
      helpPanelVisible: false,
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
              placeholderSuppressed: false,
              activity: _ActivityState.cancelling,
              activityStartedAt: null,
              notice: strings.cancellingRun,
            ),
            null,
          );
        }
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            notice: strings.noActiveRun,
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
            placeholderSuppressed: false,
            clearNotice: true,
            helpPanelVisible: true,
          ),
          null,
        );
      case '/status':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            notice: _statusSummary(),
          ),
          null,
        );
      case '/history':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            notice: strings.historyVisible(messages.length),
          ),
          null,
        );
      case '/clear':
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            messages: const [],
            activeAssistantText: '',
            notice: strings.screenCleared,
          ),
          null,
        );
      case '/session':
        if (parts.length < 2 || parts[1].trim().isEmpty) {
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              placeholderSuppressed: false,
              notice: strings.usageSession,
            ),
            null,
          );
        }
        final nextSession = parts[1].trim();
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
          ),
          _loadSessionCommand(nextSession),
        );
      case '/env':
        if (parts.length < 2 || parts[1].trim().isEmpty) {
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              placeholderSuppressed: false,
              notice: strings.usageEnv,
            ),
            null,
          );
        }
        final nextEnv = normalizeEnvironmentName(parts[1]);
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            environment: nextEnv,
            clearEnvironment: nextEnv == null,
            notice: strings.environmentSwitched(nextEnv ?? 'default'),
          ),
          null,
        );
      case '/lang':
        if (parts.length < 2 || parts[1].trim().isEmpty) {
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              placeholderSuppressed: false,
              notice: strings.usageLang,
            ),
            null,
          );
        }
        final TuiLocalePreference nextLocale;
        try {
          nextLocale = parseTuiLocalePreference(parts[1]);
        } on FormatException {
          return (
            copyWith(
              input: input.copyWith(value: '', cursorPos: 0),
              placeholderSuppressed: false,
              notice: strings.usageLang,
            ),
            null,
          );
        }
        final nextConfig = config.copyWith(
          tui: config.tui.copyWith(locale: nextLocale),
        );
        final nextStrings = TuiStrings.resolve(nextLocale);
        final localeName = tuiLocalePreferenceToConfig(nextLocale);
        return (
          copyWith(
            config: nextConfig,
            localePreference: nextLocale,
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            notice: nextStrings.languageSwitched(localeName),
          ),
          _saveConfigCommand(nextConfig),
        );
      default:
        return (
          copyWith(
            input: input.copyWith(value: '', cursorPos: 0),
            placeholderSuppressed: false,
            notice: strings.unknownCommand(command),
          ),
          null,
        );
    }
  }

  Cmd _saveConfigCommand(AppConfig nextConfig) {
    return () async {
      try {
        await configStore.save(nextConfig);
        return null;
      } catch (error) {
        return _AgentErrorMsg('$error');
      }
    };
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
      send(_AgentWaitingMsg());
      final result = await agentService.runTurnStreaming(
        message: value,
        sessionId: sessionId,
        environment: environment,
        cancellationToken: cancellation.token,
        onDelta: (delta) => send(_AgentDeltaMsg(delta)),
        onToolCall: (call) => send(_ToolStartedMsg(call)),
        onToolResult: (result) => send(_ToolFinishedMsg(result)),
        toolPolicyOverride: _interactiveToolPolicy(),
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
    final contentWidth = (width - 2).clamp(20, 200).toInt();
    final compactLayout = _isCompactLayout;
    final tightLayout = _isTightLayout;
    final headerLines = _buildHeaderLines(contentWidth, compact: compactLayout);
    final bodyLines = _buildBodyLines(contentWidth);
    final inputView = _footerInputView(contentWidth, compact: compactLayout);
    var footerLines = _buildFooterLines(
      contentWidth,
      inputView: inputView,
      compact: compactLayout,
      tight: tightLayout,
    );
    var bodyViewportHeight =
        _bodyViewportHeight(headerLines.length, footerLines.length);
    final showScrollStatus =
        bodyLines.length > bodyViewportHeight || scrollOffset > 0;
    if (showScrollStatus) {
      footerLines = _buildFooterLines(
        contentWidth,
        inputView: inputView,
        compact: compactLayout,
        tight: tightLayout,
        scrollText: strings.scrollLatest(),
      );
      bodyViewportHeight =
          _bodyViewportHeight(headerLines.length, footerLines.length);
    }
    final maxScrollOffset =
        (bodyLines.length - bodyViewportHeight).clamp(0, 1000000).toInt();
    final effectiveScrollOffset =
        scrollOffset.clamp(0, maxScrollOffset).toInt();
    if (showScrollStatus) {
      footerLines = _buildFooterLines(
        contentWidth,
        inputView: inputView,
        compact: compactLayout,
        tight: tightLayout,
        scrollText: effectiveScrollOffset > 0
            ? strings.scrollAbove(
                effectiveScrollOffset,
                compact: compactLayout,
              )
            : strings.scrollLatest(),
      );
    }
    final visibleEnd = bodyLines.length - effectiveScrollOffset;
    final visibleStart =
        (visibleEnd - bodyViewportHeight).clamp(0, bodyLines.length);
    final visibleBodyLines = [
      ...bodyLines.sublist(visibleStart, visibleEnd),
    ];
    while (visibleBodyLines.length < bodyViewportHeight) {
      visibleBodyLines.add('');
    }
    final lines = <String>[
      ...headerLines,
      ...visibleBodyLines,
      ...footerLines,
    ];

    final view = newView(lines.join('\n'));
    view.cursor =
        Cursor(x: inputView.cursorX, y: lines.length - 1, blink: true);
    return view;
  }

  String _statusSummary() {
    final envConfig = config.resolveEnvironment(environment);
    final provider = envConfig.provider;
    final gateway = envConfig.gateway;
    final toolPolicy = envConfig.toolPolicy;
    final elapsed = _elapsedStatus(activityStartedAt);
    final apiKeyConfigured =
        (provider.apiKey != null && provider.apiKey!.isNotEmpty) ||
            (Platform.environment[provider.apiKeyEnv]?.isNotEmpty ?? false);
    final sessionPolicyCount =
        toolPolicy.sessions[normalizeToolPolicySessionId(sessionId)]?.length ??
            0;
    final activeDetail = strings.activity(activity.label, elapsed: elapsed);
    return [
      strings.statusHeading,
      'activity: $activeDetail',
      'environment: ${environment ?? 'default'}',
      'session: $sessionId',
      'messages: ${messages.length} visible',
      'provider: ${provider.kind} ${provider.model}',
      'baseUrl: ${provider.baseUrl}',
      'apiKey: ${apiKeyConfigured ? 'configured' : 'missing'} (${provider.apiKeyEnv})',
      'gateway: ${gateway.host}:${gateway.port}',
      'tui.locale: ${tuiLocalePreferenceToConfig(localePreference)} (${strings.languageName})',
      'tool policy: ${toolPolicy.explicitDecisionCount} decision(s), $sessionPolicyCount for this session',
      'interactive permission: ask by default, ${sessionAllowedTools.length} allow(s) for this TUI session',
      'ui: thinking=${showThinking ? 'on' : 'off'}, toolDetails=${toolDetailsExpanded ? 'expanded' : 'collapsed'}',
    ].join('\n');
  }

  ToolPermissionPolicy _interactiveToolPolicy() {
    final configured = config.resolveEnvironment(environment).toolPolicy;
    final sessionKey = normalizeToolPolicySessionId(sessionId);
    final toolDenies = <String, ToolPolicyDecision>{
      for (final entry in configured.tools.entries)
        if (entry.value == ToolPolicyDecision.deny) entry.key: entry.value,
    };
    final sessionDecisions = <String, ToolPolicyDecision>{
      for (final entry in (configured.sessions[sessionKey] ?? const {}).entries)
        if (entry.value == ToolPolicyDecision.deny) entry.key: entry.value,
      for (final tool in sessionAllowedTools) tool: ToolPolicyDecision.allow,
    };
    return ToolPermissionPolicy(
      tools: toolDenies,
      sessions: sessionDecisions.isEmpty
          ? const {}
          : {
              sessionKey: sessionDecisions,
            },
    );
  }

  List<String> _buildBodyLines(int contentWidth) {
    final bodyLines = <String>[];
    if (messages.isEmpty && activeAssistantText.isEmpty) {
      bodyLines.add(strings.historyEmpty);
      return bodyLines;
    }
    for (final message in messages) {
      bodyLines.addAll(
        _renderChatLine(
          message,
          contentWidth: contentWidth,
          expandToolDetails: toolDetailsExpanded,
          strings: strings,
        ),
      );
    }
    if (activeAssistantText.isNotEmpty) {
      bodyLines
          .addAll(_wrapLine('assistant> $activeAssistantText', contentWidth));
    }
    return bodyLines;
  }

  List<String> _buildHeaderLines(int contentWidth, {required bool compact}) {
    final envConfig = config.resolveEnvironment(environment);
    final contextLine =
        'dartsub tui | env=${environment ?? 'default'} | session=$sessionId | lang=${_languageStatusLabel()}';
    final modelLine =
        'model=${envConfig.provider.model} | api=${_compactBaseUrl(envConfig.provider.baseUrl)}';
    if (compact) {
      return [
        ..._wrapLine(contextLine, contentWidth),
        if (!_isTightLayout) ..._wrapLine(modelLine, contentWidth),
        ..._wrapLine(_activityLine(compact: true), contentWidth),
        '',
      ];
    }
    return [
      ..._wrapLine(contextLine, contentWidth),
      ..._wrapLine(modelLine, contentWidth),
      ..._wrapLine(_activityLine(), contentWidth),
      ..._wrapLine(strings.helpHint, contentWidth),
      '',
    ];
  }

  String _languageStatusLabel() {
    final preference = tuiLocalePreferenceToConfig(localePreference);
    return '$preference (${strings.languageName})';
  }

  String _compactBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) {
      return baseUrl;
    }
    return uri.host;
  }

  List<String> _buildFooterLines(
    int contentWidth, {
    required _InputRender inputView,
    required bool compact,
    required bool tight,
    String? scrollText,
  }) {
    final lines = <String>[
      if (!tight) '',
    ];
    if (pendingToolPermission != null) {
      lines.addAll(_permissionPanel(
        pendingToolPermission!.request,
        contentWidth: contentWidth,
        expanded: toolDetailsExpanded,
        compact: compact,
        tight: tight,
        strings: strings,
      ));
    }
    final slashSuggestions = _slashSuggestions();
    if (showThinking &&
        thinking &&
        activeAssistantText.isEmpty &&
        pendingToolPermission == null) {
      lines.add(spinner.view().content);
    }
    if (notice != null && notice!.isNotEmpty) {
      lines.addAll(
        _wrapLine('${strings.noticePrefix}: $notice', contentWidth)
            .map(_styleNoticeLine),
      );
    }
    if (scrollText != null) {
      lines.add(compact ? _compactScrollText(scrollText) : scrollText);
    }
    if (helpPanelVisible) {
      lines.addAll(_helpPanel(
        contentWidth: contentWidth,
        compact: compact,
        tight: tight,
      ));
    }
    if (slashSuggestions.isNotEmpty) {
      lines.addAll(_slashSuggestionPanel(
        slashSuggestions,
        contentWidth: contentWidth,
        compact: compact,
        tight: tight,
      ));
    }
    lines.add(inputView.line);
    return lines;
  }

  _InputRender _footerInputView(int contentWidth, {required bool compact}) {
    if (pendingToolPermission != null) {
      final line = strings.choiceLine(
        compact: compact,
        contentWidth: contentWidth,
      );
      return _InputRender(
        line: line,
        cursorX: _displayWidth('choice> '),
      );
    }
    return _renderInput(
      input,
      contentWidth,
      showPlaceholder: input.value.isEmpty && !placeholderSuppressed,
    );
  }

  List<_SlashSuggestion> _slashSuggestions() {
    if (pendingToolPermission != null ||
        slashSuggestionsDismissed ||
        !input.value.startsWith('/')) {
      return const [];
    }
    final raw = input.value;
    final trimmedLeft = raw.trimLeft();
    final argumentSuggestions = switch (_slashArgumentCommand(trimmedLeft)) {
      '/lang' => _localeSlashSuggestions(_slashArgumentPrefix(trimmedLeft)),
      '/env' => _environmentSlashSuggestions(_slashArgumentPrefix(trimmedLeft)),
      '/session' => _sessionSlashSuggestions(_slashArgumentPrefix(trimmedLeft)),
      _ => null,
    };
    if (argumentSuggestions != null) {
      return argumentSuggestions;
    }
    if (trimmedLeft.contains(RegExp(r'\s'))) {
      return const [];
    }
    final prefix = trimmedLeft.toLowerCase();
    return [
      for (final command in _slashCommands)
        if (command.command.startsWith(prefix))
          _SlashSuggestion(
            value: command.command,
            completionValue: command.requiresArgument
                ? '${command.command} '
                : command.command,
            label: command.command,
            description: strings.commandDescription(command.command),
            requiresArgument: command.requiresArgument,
          ),
    ];
  }

  String? _slashArgumentCommand(String value) {
    for (final command in const ['/lang', '/env', '/session']) {
      if (value == command || value.startsWith('$command ')) {
        return command;
      }
    }
    return null;
  }

  String _slashArgumentPrefix(String value) {
    final separator = value.indexOf(' ');
    if (separator == -1) {
      return '';
    }
    return value.substring(separator).trimLeft();
  }

  List<_SlashSuggestion> _localeSlashSuggestions(String prefix) {
    final normalized = prefix.toLowerCase();
    return [
      for (final locale in const ['auto', 'zh-CN', 'en-US'])
        if (locale.toLowerCase().startsWith(normalized))
          _SlashSuggestion(
            value: '/lang $locale',
            completionValue: '/lang $locale',
            label: locale,
            description: strings.localeDescription(locale),
            executeOnEnter: true,
          ),
    ];
  }

  List<_SlashSuggestion> _environmentSlashSuggestions(String prefix) {
    final normalized = prefix.toLowerCase();
    final environments = [
      'default',
      ...config.environments.keys,
    ];
    return [
      for (final environment in environments)
        if (environment.toLowerCase().startsWith(normalized))
          _SlashSuggestion(
            value: '/env $environment',
            completionValue: '/env $environment',
            label: environment,
            description: strings.environmentDescription(environment),
            executeOnEnter: true,
          ),
    ];
  }

  List<_SlashSuggestion> _sessionSlashSuggestions(String prefix) {
    final normalized = prefix.toLowerCase();
    return [
      for (final knownSession in knownSessionIds)
        if (knownSession.toLowerCase().startsWith(normalized))
          _SlashSuggestion(
            value: '/session $knownSession',
            completionValue: '/session $knownSession',
            label: knownSession,
            description: strings.sessionDescription(
              knownSession,
              current: knownSession == sessionId,
            ),
            executeOnEnter: true,
          ),
    ];
  }

  List<String> _slashSuggestionPanel(
    List<_SlashSuggestion> suggestions, {
    required int contentWidth,
    required bool compact,
    required bool tight,
  }) {
    final selected = _selectedSlashSuggestionIndex(suggestions);
    final maxItems = tight
        ? 3
        : compact
            ? 4
            : 6;
    final start = (selected - maxItems + 1)
        .clamp(0, (suggestions.length - maxItems).clamp(0, suggestions.length))
        .toInt();
    final visible = suggestions.skip(start).take(maxItems).toList();
    final lines = <String>[
      for (var i = 0; i < visible.length; i += 1)
        _slashSuggestionLine(
          visible[i],
          selected: start + i == selected,
          compact: compact,
        ),
      if (!tight) strings.slashPanelHint,
    ];
    return _boxedLines(
      title: strings.slashPanelTitle,
      lines: lines,
      width: contentWidth,
    );
  }

  String _slashSuggestionLine(
    _SlashSuggestion suggestion, {
    required bool selected,
    required bool compact,
  }) {
    final marker = selected ? '>' : ' ';
    if (compact || suggestion.description.isEmpty) {
      return '$marker ${suggestion.label}';
    }
    return '$marker ${suggestion.label}  ${suggestion.description}';
  }

  List<String> _helpPanel({
    required int contentWidth,
    required bool compact,
    required bool tight,
  }) {
    final commands = [
      for (final command in _slashCommands)
        '${command.command}${command.requiresArgument ? ' <value>' : ''}  ${strings.commandDescription(command.command)}',
    ];
    final lines = tight
        ? [
            ...commands.take(4),
            strings.helpPanelShortcuts.last,
          ]
        : compact
            ? [
                ...commands.take(6),
                ...strings.helpPanelShortcuts.take(3),
              ]
            : [
                ...commands,
                '',
                ...strings.helpPanelShortcuts,
              ];
    return _boxedLines(
      title: strings.helpPanelTitle,
      lines: lines,
      width: contentWidth,
    );
  }

  int _bodyViewportHeight(int headerLineCount, int footerLineCount) {
    return (height - headerLineCount - footerLineCount).clamp(1, 200).toInt();
  }

  bool get _isCompactLayout => height <= 18 || width <= 72;

  bool get _isTightLayout => height <= 12 || width <= 52;

  int? _activityStartedAt(_ActivityState next) {
    if (!next.isActive) {
      return null;
    }
    if (activity == next && activityStartedAt != null) {
      return activityStartedAt;
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  String _activityLine({bool compact = false}) {
    final pending = pendingToolPermission;
    if (pending != null) {
      return strings.permissionStatus(pending.request.tool, compact: compact);
    }
    final elapsed = _elapsedStatus(activityStartedAt);
    final detail = strings.activity(activity.label, elapsed: elapsed);
    return strings.statusLine(
      detail,
      thinkingVisible: showThinking,
      thinking: thinking,
      compact: compact,
    );
  }
}

List<String> _permissionPanel(
  ToolPermissionRequest request, {
  required int contentWidth,
  required bool expanded,
  required bool compact,
  required bool tight,
  required TuiStrings strings,
}) {
  final args = _oneLine(jsonEncode(request.arguments));
  final body = tight
      ? <String>[
          if (expanded)
            strings.args(args)
          else
            '${strings.toolLabel}: ${request.tool} | ${strings.riskLabel}: ${request.risk.name}',
        ]
      : compact
          ? <String>[
              '${strings.toolLabel}: ${request.tool} | ${strings.riskLabel}: ${request.risk.name}',
              if (expanded)
                strings.args(args)
              else
                strings.hiddenArgs(compact: true),
              strings.compactPermissionChoices,
            ]
          : <String>[
              strings.permissionPaused,
              '${strings.toolLabel}: ${request.tool}',
              '${strings.riskLabel}: ${request.risk.name}',
              if (expanded)
                strings.args(args)
              else
                strings.hiddenArgs(compact: false),
              strings.permissionChoices,
            ];
  return _boxedLines(
    title: strings.permissionTitle,
    lines: body,
    width: contentWidth,
  );
}

String _compactScrollText(String scrollText) {
  final match = RegExp(r'^scroll: (\d+) line').firstMatch(scrollText);
  if (match != null) {
    return 'scroll: +${match.group(1)}';
  }
  return scrollText;
}

List<String> _boxedLines({
  required String title,
  required List<String> lines,
  required int width,
}) {
  final boxWidth = width.clamp(24, 120).toInt();
  final innerWidth = (boxWidth - 4).clamp(10, 116).toInt();
  final output = <String>[
    '+${'-' * (boxWidth - 2)}+',
    '| ${_padRightDisplay(title, innerWidth)} |',
    '+${'-' * (boxWidth - 2)}+',
  ];
  for (final line in lines) {
    for (final wrapped in _wrapLine(line, innerWidth)) {
      output.add('| ${_padRightDisplay(wrapped, innerWidth)} |');
    }
  }
  output.add('+${'-' * (boxWidth - 2)}+');
  return output;
}

String _padRightDisplay(String value, int width) {
  final displayWidth = _displayWidth(value);
  if (displayWidth >= width) {
    return value;
  }
  return '$value${' ' * (width - displayWidth)}';
}

String _styleUserMessageLine(String line, int width) {
  return '$_userMessageStyle${_padRightDisplay(line, width)}$_ansiReset';
}

String _styleToolLine(String line) {
  return '$_toolMessageStyle$line$_ansiReset';
}

String _styleNoticeLine(String line) {
  return '$_noticeStyle$line$_ansiReset';
}

List<String> _renderChatLine(
  _ChatLine message, {
  required int contentWidth,
  required bool expandToolDetails,
  required TuiStrings strings,
}) {
  switch (message.kind) {
    case _ChatLineKind.user:
      return [
        for (final line in _wrapLine('you> ${message.content}', contentWidth))
          _styleUserMessageLine(line, contentWidth),
      ];
    case _ChatLineKind.assistant:
      return _wrapLine('assistant> ${message.content}', contentWidth);
    case _ChatLineKind.tool:
      return _renderToolEvent(
        message.tool!,
        contentWidth: contentWidth,
        expandDetails: expandToolDetails,
        strings: strings,
      );
  }
}

List<String> _renderToolEvent(
  _ToolEvent event, {
  required int contentWidth,
  required bool expandDetails,
  required TuiStrings strings,
}) {
  final lines = <String>[
    for (final line in _wrapLine(event.summary(strings), contentWidth))
      _styleToolLine(line),
  ];
  if (!expandDetails) {
    return lines;
  }
  for (final section in event.detailSections(strings)) {
    lines.addAll(
      _renderToolDetailSection(
        section,
        contentWidth: contentWidth,
      ).map(_styleToolLine),
    );
  }
  return lines;
}

List<String> _renderToolDetailSection(
  _ToolDetailSection section, {
  required int contentWidth,
}) {
  const detailIndent = '  ';
  const valueIndent = '    ';
  final value = section.value.trimRight();
  return [
    ..._wrapLine('$detailIndent${section.label}>', contentWidth),
    if (value.isEmpty)
      valueIndent
    else
      ..._wrapIndentedBlock(
        value,
        contentWidth: contentWidth,
        indent: valueIndent,
      ),
  ];
}

List<String> _wrapIndentedBlock(
  String value, {
  required int contentWidth,
  required String indent,
}) {
  final indentWidth = _displayWidth(indent);
  final valueWidth = (contentWidth - indentWidth).clamp(1, 200).toInt();
  return [
    for (final line in _wrapLine(value, valueWidth)) '$indent$line',
  ];
}

List<_ChatLine> _completeRunningTool(
  List<_ChatLine> messages,
  ToolResult result,
) {
  final nextMessages = [...messages];
  for (var i = nextMessages.length - 1; i >= 0; i -= 1) {
    final line = nextMessages[i];
    final event = line.tool;
    if (event != null &&
        event.status == _ToolEventStatus.running &&
        event.tool == result.tool) {
      nextMessages[i] = _ChatLine.tool(event.complete(result));
      return nextMessages;
    }
  }
  nextMessages.add(_ChatLine.tool(_ToolEvent.fromResult(result)));
  return nextMessages;
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

_InputRender _renderInput(
  TextInputModel input,
  int maxWidth, {
  required bool showPlaceholder,
}) {
  const prompt = 'you> ';
  final promptWidth = _displayWidth(prompt);
  final availableWidth = (maxWidth - promptWidth).clamp(10, 180);
  if (input.value.isEmpty && showPlaceholder) {
    final placeholder = _takeDisplayWidth(input.placeholder, availableWidth);
    return _InputRender(line: '$prompt$placeholder', cursorX: promptWidth);
  }
  if (input.value.isEmpty) {
    return _InputRender(line: prompt, cursorX: promptWidth);
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

String? _elapsedStatus(int? startedAt) {
  if (startedAt == null) {
    return null;
  }
  final elapsedMs = DateTime.now().millisecondsSinceEpoch - startedAt;
  final totalSeconds = (elapsedMs ~/ 1000).clamp(0, 1 << 30);
  if (totalSeconds < 60) {
    return '${totalSeconds}s';
  }
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes}m ${seconds}s';
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

final class _SlashCommand {
  const _SlashCommand(this.command, {this.requiresArgument = false});

  final String command;
  final bool requiresArgument;
}

const List<_SlashCommand> _slashCommands = [
  _SlashCommand('/help'),
  _SlashCommand('/status'),
  _SlashCommand('/history'),
  _SlashCommand('/session', requiresArgument: true),
  _SlashCommand('/env', requiresArgument: true),
  _SlashCommand('/lang', requiresArgument: true),
  _SlashCommand('/clear'),
  _SlashCommand('/cancel'),
  _SlashCommand('/exit'),
  _SlashCommand('/quit'),
];

final class _SlashSuggestion {
  const _SlashSuggestion({
    required this.value,
    required this.completionValue,
    required this.label,
    required this.description,
    this.requiresArgument = false,
    this.executeOnEnter = false,
  });

  final String value;
  final String completionValue;
  final String label;
  final String description;
  final bool requiresArgument;
  final bool executeOnEnter;
}

enum _ChatLineKind { user, assistant, tool }

final class _ChatLine {
  _ChatLine(this.kind, this.content, {this.tool});

  factory _ChatLine.user(String content) =>
      _ChatLine(_ChatLineKind.user, content);

  factory _ChatLine.assistant(String content) =>
      _ChatLine(_ChatLineKind.assistant, content);

  factory _ChatLine.tool(_ToolEvent tool) =>
      _ChatLine(_ChatLineKind.tool, '', tool: tool);

  final _ChatLineKind kind;
  final String content;
  final _ToolEvent? tool;
}

enum _ToolEventStatus { running, completed, failed, denied }

final class _ToolDetailSection {
  _ToolDetailSection(this.label, this.value);

  final String label;
  final String value;
}

final class _ToolEvent {
  _ToolEvent({
    required this.tool,
    required this.arguments,
    required this.status,
    this.output,
    this.exitCode,
  });

  factory _ToolEvent.running(ToolCall call) {
    return _ToolEvent(
      tool: call.tool,
      arguments: call.arguments,
      status: _ToolEventStatus.running,
    );
  }

  factory _ToolEvent.fromResult(ToolResult result) {
    return _ToolEvent(
      tool: result.tool,
      arguments: const {},
      status: _statusForResult(result),
      output: result.output,
      exitCode: result.exitCode,
    );
  }

  final String tool;
  final Map<String, Object?> arguments;
  final _ToolEventStatus status;
  final String? output;
  final int? exitCode;

  _ToolEvent complete(ToolResult result) {
    return _ToolEvent(
      tool: result.tool,
      arguments: arguments,
      status: _statusForResult(result),
      output: result.output,
      exitCode: result.exitCode,
    );
  }

  String summary(TuiStrings strings) {
    final exit = exitCode == null ? '' : ' exit=$exitCode';
    return 'tool> $tool ${strings.toolStatus(status.name)}$exit';
  }

  List<_ToolDetailSection> detailSections(TuiStrings strings) {
    final sections = <_ToolDetailSection>[
      if (arguments.isNotEmpty)
        _ToolDetailSection(strings.toolArgumentsLabel, jsonEncode(arguments)),
      if (status == _ToolEventStatus.denied)
        _ToolDetailSection(
          strings.toolPermissionLabel,
          strings.toolDeniedByUser,
        ),
    ];
    final resultOutput = output?.trimRight() ?? '';
    if (resultOutput.isNotEmpty) {
      sections.add(
        _ToolDetailSection(
          status == _ToolEventStatus.denied
              ? strings.toolReasonLabel
              : strings.toolOutputLabel,
          resultOutput,
        ),
      );
    }
    return sections;
  }

  static _ToolEventStatus _statusForResult(ToolResult result) {
    if (result.code == 'permission_denied') {
      return _ToolEventStatus.denied;
    }
    return result.ok ? _ToolEventStatus.completed : _ToolEventStatus.failed;
  }
}

final class _AgentDeltaMsg extends Msg {
  _AgentDeltaMsg(this.delta);
  final String delta;
}

final class _AgentWaitingMsg extends Msg {}

final class _AgentCompleteMsg extends Msg {
  _AgentCompleteMsg(this.reply);
  final String reply;
}

final class _ToolStartedMsg extends Msg {
  _ToolStartedMsg(this.call);
  final ToolCall call;
}

final class _ToolFinishedMsg extends Msg {
  _ToolFinishedMsg(this.result);
  final ToolResult result;
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
