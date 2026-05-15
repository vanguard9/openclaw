class InboundMessage {
  InboundMessage({
    required this.channel,
    required this.sender,
    required this.text,
    this.threadId,
  });

  final String channel;
  final String sender;
  final String text;
  final String? threadId;
}

abstract interface class Channel {
  String get id;

  Future<void> start();

  Future<void> stop();

  Future<void> sendText({
    required String recipient,
    required String text,
    String? threadId,
  });
}
