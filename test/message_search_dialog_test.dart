import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/chat/message_search_dialog.dart';

void main() {
  testWidgets('点击搜索结果会返回对应消息，并使用当前会话名称', (tester) async {
    final message = Message(
      id: 'm1',
      role: 'assistant',
      text: '中午好呀，吃饭了吗？',
      attachments: const [],
      at: DateTime(2026, 11, 13, 12),
      seq: 1,
    );
    Message? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showDialog<Message>(
                  context: context,
                  builder: (_) => MessageSearchDialog(
                    messages: [message],
                    assistantName: '在吗，测一句',
                  ),
                );
              },
              child: const Text('打开搜索'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '好');
    await tester.pumpAndSettle();

    expect(find.text('在吗，测一句'), findsOneWidget);
    await tester.tap(find.text('在吗，测一句'));
    await tester.pumpAndSettle();

    expect(selected?.id, 'm1');
  });
}
