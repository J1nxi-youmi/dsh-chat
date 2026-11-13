import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_chat/src/chat/message_bubble.dart';
import 'package:dsh_chat/src/core/models.dart';

void main() {
  testWidgets('长按消息弹出四项操作，删除会回调', (tester) async {
    var deleted = false;
    final message = Message(
      id: 'm1',
      role: 'assistant',
      text: '这是一条测试消息',
      attachments: const [],
      at: DateTime(2026, 11, 14, 4, 40),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            mediaUrl: (value) => value,
            onReply: () {},
            onShare: () {},
            onDelete: () => deleted = true,
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(MessageBubble));
    await tester.pumpAndSettle();

    expect(find.text('复制文字'), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);
    expect(find.text('分享到群'), findsOneWidget);
    expect(find.text('删除本地显示'), findsOneWidget);

    await tester.tap(find.text('删除本地显示'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });
}
