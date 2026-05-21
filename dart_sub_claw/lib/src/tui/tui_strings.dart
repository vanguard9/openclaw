import 'dart:io';

enum TuiLocalePreference { auto, zhCn, enUs }

enum TuiLocale { zhCn, enUs }

TuiLocalePreference parseTuiLocalePreference(String raw) {
  final normalized = raw.trim().toLowerCase().replaceAll('_', '-');
  return switch (normalized) {
    'auto' || '' => TuiLocalePreference.auto,
    'zh' || 'zh-cn' || 'zh-hans' => TuiLocalePreference.zhCn,
    'en' || 'en-us' => TuiLocalePreference.enUs,
    _ => throw FormatException('tui.locale must be auto, zh-CN, or en-US.'),
  };
}

String tuiLocalePreferenceToConfig(TuiLocalePreference preference) {
  return switch (preference) {
    TuiLocalePreference.auto => 'auto',
    TuiLocalePreference.zhCn => 'zh-CN',
    TuiLocalePreference.enUs => 'en-US',
  };
}

TuiLocale resolveTuiLocale(
  TuiLocalePreference preference, {
  Map<String, String>? environment,
}) {
  return switch (preference) {
    TuiLocalePreference.zhCn => TuiLocale.zhCn,
    TuiLocalePreference.enUs => TuiLocale.enUs,
    TuiLocalePreference.auto => _localeFromEnvironment(
        environment ?? Platform.environment,
      ),
  };
}

TuiLocale _localeFromEnvironment(Map<String, String> environment) {
  final raw = [
    environment['DARTSUB_TUI_LOCALE'],
    environment['LC_ALL'],
    environment['LC_MESSAGES'],
    environment['LANG'],
  ].whereType<String>().join(' ').toLowerCase();
  return raw.contains('zh') ? TuiLocale.zhCn : TuiLocale.enUs;
}

final class TuiStrings {
  TuiStrings(this.locale);

  factory TuiStrings.resolve(TuiLocalePreference preference) {
    return TuiStrings(resolveTuiLocale(preference));
  }

  final TuiLocale locale;

  bool get _zh => locale == TuiLocale.zhCn;

  String get languageName => _zh ? '中文' : 'English';

  String get helpHint => _zh ? '/help 查看命令' : '/help for commands';

  String get commandsLine => _zh
      ? '命令: /help /status /history /debug /new /reset /session <id> /env <name|default> /lang <auto|zh-CN|en-US> /clear /cancel /exit'
      : 'commands: /help /status /history /debug /new /reset /session <id> /env <name|default> /lang <auto|zh-CN|en-US> /clear /cancel /exit';

  String get help => _zh
      ? '命令: /help 帮助 | /status 状态 | /history 历史 | /debug 调试视图 | /new 新上下文 | /reset 重置上下文 | /session <id> 切换会话 | /env <name|default> 切换环境 | /lang <auto|zh-CN|en-US> 切换语言 | /clear 清屏 | /cancel 取消 | /exit 退出'
      : 'commands: /help /status /history /debug /new /reset /session <id> /env <name|default> /lang <auto|zh-CN|en-US> /clear /cancel /exit';

  String get slashPanelTitle => _zh ? '命令选择' : 'Command suggestions';

  String get slashPanelHint => _zh
      ? '↑/↓ 选择 · Tab 补全 · Enter 应用'
      : '↑/↓ select · Tab complete · Enter apply';

  String get helpPanelTitle => _zh ? 'TUI 帮助' : 'TUI help';

  List<String> get helpPanelShortcuts => _zh
      ? const [
          '快捷键: ↑/↓ 输入历史或面板选择',
          'Tab 补全 slash 命令',
          'Esc 关闭面板或取消运行',
          'Ctrl-O 展开 tool/debug 详情',
          'Ctrl-T 切换 thinking 显示',
        ]
      : const [
          'keys: ↑/↓ input history or panel selection',
          'Tab completes slash commands',
          'Esc closes panels or cancels a run',
          'Ctrl-O expands tool/debug details',
          'Ctrl-T toggles thinking display',
        ];

  String commandDescription(String command) {
    return switch (command) {
      '/help' => _zh ? '显示帮助' : 'show help',
      '/status' => _zh ? '显示状态' : 'show status',
      '/history' => _zh ? '显示可见历史数量' : 'show visible history count',
      '/debug' => _zh ? '切换调试视图' : 'toggle debug view',
      '/new' => _zh ? '新建上下文' : 'start fresh context',
      '/reset' => _zh ? '重置上下文' : 'reset context',
      '/session' => _zh ? '切换 session' : 'switch session',
      '/env' => _zh ? '切换 environment' : 'switch environment',
      '/lang' => _zh ? '切换 TUI 语言' : 'switch TUI language',
      '/clear' => _zh ? '清空屏幕' : 'clear screen',
      '/cancel' => _zh ? '取消当前运行' : 'cancel active run',
      '/exit' || '/quit' => _zh ? '退出 TUI' : 'exit TUI',
      _ => '',
    };
  }

  String localeDescription(String locale) {
    return switch (locale) {
      'auto' => _zh ? '跟随系统语言' : 'follow system language',
      'zh-CN' => _zh ? '中文' : 'Chinese',
      'en-US' => _zh ? '英文' : 'English',
      _ => '',
    };
  }

  String environmentDescription(String environment) {
    if (environment == 'default') {
      return _zh ? '默认 environment' : 'default environment';
    }
    return _zh ? '切换到 environment' : 'switch environment';
  }

  String sessionDescription(String session, {required bool current}) {
    if (current) {
      return _zh ? '当前 session' : 'current session';
    }
    return _zh ? '切换到 session' : 'switch session';
  }

  String get statusHeading => _zh ? '状态:' : 'status:';

  String get noticePrefix => _zh ? '提示' : 'notice';

  String get historyEmpty => _zh ? 'history: 空' : 'history: empty';

  String activity(String label, {String? elapsed}) {
    final localized = switch (label) {
      'idle' => _zh ? '空闲' : 'idle',
      'sending' => _zh ? '发送中' : 'sending',
      'waiting' => _zh ? '等待中' : 'waiting',
      'streaming' => _zh ? '生成中' : 'streaming',
      'permission required' => _zh ? '需要授权' : 'permission required',
      'cancelling' => _zh ? '取消中' : 'cancelling',
      'cancelled' => _zh ? '已取消' : 'cancelled',
      'error' => _zh ? '错误' : 'error',
      _ => label,
    };
    if (elapsed == null) {
      return localized;
    }
    return _zh ? '$localized $elapsed' : '$localized for $elapsed';
  }

  String permissionStatus(String tool, {required bool compact}) {
    if (_zh) {
      return compact
          ? '状态=授权: $tool | y/a/n'
          : '状态=需要授权: $tool | y 允许一次 | a 本会话允许 | n 拒绝';
    }
    return compact
        ? 'status=permission: $tool | y/a/n'
        : 'status=permission required: $tool | y allow once | a allow session | n deny';
  }

  String statusLine(
    String detail, {
    required bool thinkingVisible,
    required bool thinking,
    required bool compact,
  }) {
    final cancelHint = thinking ? (_zh ? ' | Esc 取消' : ' | Esc cancels') : '';
    if (compact) {
      return (_zh ? '状态=$detail' : 'status=$detail') + cancelHint;
    }
    final thinkingHint = _zh
        ? 'thinking=${thinkingVisible ? '开' : '关'}'
        : 'thinking=${thinkingVisible ? 'on' : 'off'}';
    return (_zh ? '状态=$detail' : 'status=$detail') +
        ' | $thinkingHint$cancelHint';
  }

  String get permissionTitle => _zh ? '需要用户授权' : 'Permission required';

  String get permissionPaused => _zh
      ? 'AI 已暂停，正在等待你的授权决定。'
      : 'AI is paused and waiting for your permission.';

  String get toolLabel => _zh ? '工具' : 'tool';

  String get riskLabel => _zh ? '风险级别' : 'risk';

  String hiddenArgs({required bool compact}) => _zh
      ? (compact ? 'Ctrl-O 展开参数' : '参数: 已隐藏，按 Ctrl-O 展开详情')
      : (compact
          ? 'Ctrl-O expands arguments'
          : 'arguments: hidden, press Ctrl-O for details');

  String args(String value) => _zh ? '参数: $value' : 'arguments: $value';

  String get permissionChoices => _zh
      ? '按 y 允许一次，按 a 本会话允许，按 n 拒绝。'
      : 'Press y to allow once, a to allow for this session, n to deny.';

  String get compactPermissionChoices => _zh
      ? 'y 允许一次 | a 本会话允许 | n 拒绝'
      : 'y allow once | a allow session | n deny';

  String invalidPermissionChoice() => _zh
      ? '按 y 允许一次，按 a 本会话允许，按 n 拒绝'
      : 'Press y to allow once, a to allow for this session, n to deny';

  String choiceLine({required bool compact, required int contentWidth}) {
    final fullLine = _zh
        ? (compact
            ? 'choice> y 允许 | a 本会话 | n 拒绝'
            : 'choice> y 允许一次 | a 本会话允许 | n 拒绝')
        : (compact
            ? 'choice> y allow | a session | n deny'
            : 'choice> y allow once | a allow session | n deny');
    return _displayWidth(fullLine) <= contentWidth ? fullLine : 'choice> y/a/n';
  }

  String clearedInput() =>
      _zh ? '已清空输入；再次按 Ctrl-C 退出' : 'cleared input; press ctrl+c again to exit';

  String pressCtrlCToExit() =>
      _zh ? '再次按 Ctrl-C 退出' : 'press ctrl+c again to exit';

  String get cancellingRun => _zh ? '正在取消运行...' : 'cancelling run...';

  String get runCancelled => _zh ? '运行已取消' : 'run cancelled';

  String error(String message) => _zh ? '错误: $message' : 'error: $message';

  String toolDetails(bool expanded) => _zh
      ? (expanded ? 'tool/debug 详情已展开' : 'tool/debug 详情已折叠')
      : (expanded
          ? 'tool/debug details expanded'
          : 'tool/debug details collapsed');

  String debugDetails(bool expanded) => _zh
      ? (expanded ? 'debug 详情已展开' : 'debug 详情已折叠')
      : (expanded ? 'debug details expanded' : 'debug details collapsed');

  String thinkingDisplay(bool enabled) => _zh
      ? (enabled ? 'thinking 显示已开启' : 'thinking 显示已关闭')
      : (enabled ? 'thinking display on' : 'thinking display off');

  String debugDisplay(bool enabled) => _zh
      ? (enabled ? 'debug 视图已开启' : 'debug 视图已关闭')
      : (enabled ? 'debug view on' : 'debug view off');

  String debugPanelTitle({required bool expanded}) => _zh
      ? 'Debug: agent 与 LLM${expanded ? '，Ctrl-O 折叠详情' : '，Ctrl-O 展开详情'}'
      : 'Debug: agent and LLM${expanded ? ', Ctrl-O hides details' : ', Ctrl-O expands details'}';

  String get debugEmpty => _zh
      ? '等待下一次 agent 与 LLM 交互'
      : 'waiting for the next agent and LLM exchange';

  String sessionSwitched(String sessionId) =>
      _zh ? '已切换 session 到 $sessionId' : 'session switched to $sessionId';

  String allowedTool(String tool, {required bool forSession}) {
    if (_zh) {
      return forSession ? '本 TUI session 已允许 tool $tool' : '已允许 tool $tool';
    }
    return forSession
        ? 'allowed tool $tool for this TUI session'
        : 'allowed tool $tool';
  }

  String deniedTool(String tool) =>
      _zh ? '已拒绝 tool $tool' : 'denied tool $tool';

  String toolStatus(String status) {
    return switch (status) {
      'running' => _zh ? '执行中' : 'running',
      'completed' => _zh ? '已完成' : 'completed',
      'failed' => _zh ? '失败' : 'failed',
      'denied' => _zh ? '被拒绝' : 'denied',
      _ => status,
    };
  }

  String get toolArgumentsLabel => _zh ? '参数' : 'arguments';

  String get toolOutputLabel => _zh ? '输出' : 'output';

  String get toolReasonLabel => _zh ? '原因' : 'reason';

  String get toolPermissionLabel => _zh ? '授权' : 'permission';

  String get toolDeniedByUser => _zh ? '被用户拒绝' : 'denied by user';

  String get assistantBusy => _zh
      ? 'assistant 仍在回复；使用 /cancel 或 Esc'
      : 'assistant is still responding; use /cancel or Esc';

  String get noActiveRun => _zh ? '没有正在运行的任务' : 'no active run';

  String historyVisible(int count) =>
      _zh ? '$count 条可见消息' : '$count visible message(s)';

  String get screenCleared =>
      _zh ? '屏幕已清空；session 历史已保留' : 'screen cleared; session history kept';

  String sessionReset(String sessionId) => _zh
      ? 'session $sessionId 已重置；旧历史已归档'
      : 'session $sessionId reset; previous history archived';

  String get usageSession => _zh ? '用法: /session <id>' : 'usage: /session <id>';

  String get usageEnv =>
      _zh ? '用法: /env <name|default>' : 'usage: /env <name|default>';

  String get usageLang =>
      _zh ? '用法: /lang <auto|zh-CN|en-US>' : 'usage: /lang <auto|zh-CN|en-US>';

  String environmentSwitched(String environment) => _zh
      ? '已切换 environment 到 $environment'
      : 'environment switched to $environment';

  String languageSwitched(String locale) =>
      _zh ? '语言已切换到 $locale' : 'language switched to $locale';

  String unknownCommand(String command) =>
      _zh ? '未知命令: $command' : 'unknown command: $command';

  String scrollLatest() => _zh ? 'scroll: 最新' : 'scroll: latest';

  String scrollAbove(int count, {required bool compact}) {
    if (compact) {
      return 'scroll: +$count';
    }
    return _zh ? 'scroll: 已上移 $count 行' : 'scroll: $count line(s) above latest';
  }
}

int _displayWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    if (rune == 0) {
      continue;
    }
    if (rune < 32 || (rune >= 0x7f && rune < 0xa0)) {
      continue;
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
      width += 2;
    } else {
      width += 1;
    }
  }
  return width;
}
