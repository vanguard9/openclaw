class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String role;
  final String content;
  final DateTime createdAt;

  factory ChatMessage.fromJson(Map<String, Object?> json) {
    return ChatMessage(
      role: json['role'] as String? ?? 'user',
      content: json['content'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }

  Map<String, Object?> toJson() => {
        'role': role,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };
}
