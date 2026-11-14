import 'package:dsh_chat/src/core/update.dart';
import 'package:flutter_test/flutter_test.dart';

/// 更新检查只认 App 的 Release。
///
/// 插件（`plugin/`）也在同一个仓库发 Release，tag 是 `plugin-v0.2.6` 这种；
/// 以前版本页会把插件当成「最新版本」，这里把它钉住。
void main() {
  Map<String, dynamic> release({
    String tag = 'latest-build',
    String body = '',
    bool prerelease = false,
    bool draft = false,
    List<Map<String, dynamic>> assets = const [],
  }) =>
      {
        'tag_name': tag,
        'body': body,
        'prerelease': prerelease,
        'draft': draft,
        'assets': assets,
      };

  test('插件的 Release 不算 App 的新版本', () {
    expect(
      UpdateService.looksLikeApp(
        release(tag: 'plugin-v0.2.6', body: 'dsh-plugin-chat v0.2.6（提交 c22b286）'),
      ),
      isFalse,
    );
  });

  test('插件 Release 就算带了安装包也不算', () {
    expect(
      UpdateService.looksLikeApp(
        release(
          tag: 'plugin-v0.3.0',
          body: '<!-- build:1 -->',
          assets: [
            {'name': 'dsh-chat.apk'},
          ],
        ),
      ),
      isFalse,
    );
  });

  test('预发布不算', () {
    expect(
      UpdateService.looksLikeApp(
        release(body: '<!-- build:120 构建 #120 -->', prerelease: true),
      ),
      isFalse,
    );
  });

  test('草稿不算', () {
    expect(UpdateService.looksLikeApp(release(draft: true)), isFalse);
  });

  test('App 的 Release：正文里有构建号', () {
    expect(
      UpdateService.looksLikeApp(
        release(body: '最新版本：v1.4.4\n\n<!-- build:144 构建 #144 -->'),
      ),
      isTrue,
    );
  });

  test('App 的 Release：老版本没有注释，但有安装包附件', () {
    expect(
      UpdateService.looksLikeApp(
        release(
          tag: 'v1.2.0',
          assets: [
            {'name': 'dsh-chat.apk'},
          ],
        ),
      ),
      isTrue,
    );
  });

  test('什么都没有的 release 不算', () {
    expect(UpdateService.looksLikeApp(release(tag: 'v0.0.1')), isFalse);
  });
}
