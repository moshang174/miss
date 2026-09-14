import 'package:flutter/foundation.dart';

enum MessageRole { user, assistant, sleepNotice, memoryRecall }

@immutable
class ChatMessage {
  final int? dbId;
  final MessageRole role;
  final String content;
  final DateTime timestamp;

  const ChatMessage({
    this.dbId,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isSleepNotice => role == MessageRole.sleepNotice;
  bool get isMemoryRecall => role == MessageRole.memoryRecall;

  ChatMessage copyWith({
    int? dbId,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      dbId: dbId ?? this.dbId,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  factory ChatMessage.fromDbRow(Map<String, dynamic> row) {
    final roleStr = row['role'] as String? ?? 'assistant';
    final role = roleStr == 'user' ? MessageRole.user : MessageRole.assistant;
    final content = (row['content'] as String? ?? '').trim();
    final tsStr = row['timestamp'] as String? ?? '';
    final timestamp = DateTime.tryParse(tsStr) ?? DateTime.now();
    return ChatMessage(
      dbId: row['id'] as int?,
      role: role,
      content: content,
      timestamp: timestamp,
    );
  }
}
