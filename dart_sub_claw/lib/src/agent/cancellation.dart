import 'dart:async';

class CancelledException implements Exception {
  CancelledException([this.message = 'operation cancelled']);

  final String message;

  @override
  String toString() => message;
}

class CancellationToken {
  CancellationToken._(this._completer);

  final Completer<void> _completer;

  bool get isCancelled => _completer.isCompleted;

  Future<void> get cancelled => _completer.future;

  void throwIfCancelled() {
    if (isCancelled) {
      throw CancelledException();
    }
  }
}

class CancellationController {
  final Completer<void> _completer = Completer<void>();

  late final CancellationToken token = CancellationToken._(_completer);

  bool get isCancelled => _completer.isCompleted;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}
