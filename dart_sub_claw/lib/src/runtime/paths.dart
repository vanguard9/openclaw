import 'dart:io';

Directory resolveAppHome() {
  final explicit = Platform.environment['DART_SUB_CLAW_HOME'];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return Directory(explicit.trim());
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.trim().isEmpty) {
    throw StateError('Cannot resolve home directory. Set DART_SUB_CLAW_HOME.');
  }
  return Directory('${home.trim()}${Platform.pathSeparator}.dart_sub_claw');
}
