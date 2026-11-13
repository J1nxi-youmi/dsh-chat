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

  testWidgets('文件消息菜单显示保存、打开和文件夹操作', (tester) async {
    final message = Message(
      id: 'm2',
      role: 'assistant',
      text: '',
      attachments: [
        Attachment(
          id: 'file-1',
          kind: 'file',
          name: 'report.pdf',
          mime: 'application/pdf',
          size: 2048,
          duration: 0,
          url: '/api/files/file-1',
        ),
      ],
      at: DateTime(2026, 11, 14, 4, 41),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            mediaUrl: (value) => 'http://127.0.0.1$value',
            onDelete: () {},
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(MessageBubble));
    await tester.pumpAndSettle();

    expect(find.text('复制文字'), findsNothing);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('另存为'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('打开文件夹'), findsOneWidget);
    expect(find.text('删除本地显示'), findsOneWidget);
  });
}
