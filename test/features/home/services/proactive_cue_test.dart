import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';

class _Context extends Fake implements BuildContext {}

void main() {
  final builder = MessageBuilderService(
    chatService: ChatService(),
    contextProvider: _Context(),
  );

  test('assistant-final history gets a hidden user turn, not prefill', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'persona'},
      {'role': 'user', 'content': '晚安'},
      {'role': 'assistant', 'content': '晚安～'},
    ];
    builder.injectProactiveCue(messages, '[醒来] 现在是早上');
    expect(messages.last['role'], 'user');
    expect(messages.last['content'], startsWith(proactiveCueOpening));
    expect(messages.last['content'], contains('[醒来] 现在是早上'));
    expect(messages.first['content'], 'persona');
  });

  test('a user-final history keeps the cue in the system prompt', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'persona'},
      {'role': 'user', 'content': '在吗'},
    ];
    builder.injectProactiveCue(messages, 'cue');
    expect(messages, hasLength(2));
    expect(messages.first['content'], contains('cue'));
  });
}
