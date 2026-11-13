import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_chat/src/update.dart';

void main() {
  test('release 只显示 v1.2.2，构建号藏在注释里', () {
    final info = UpdateInfo(
      tag: 'latest-build',
      name: '最新构建',
      body:
          '最新版本：v1.2.2\n\n### 本版更新内容\n\n### 下载\n\n'
          '<!-- build:122 构建 #122 -->',
      publishedAt: DateTime(2026, 11, 14),
    );

    expect(info.versionLabel, 'v1.2.2');
    expect(info.buildNumber, 122);
  });
}
