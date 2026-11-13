import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_chat/src/core/models.dart';
import 'package:dsh_chat/src/core/profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('云端表情包会写入本地资料缓存', () async {
    SharedPreferences.setMockInitialValues({});
    final sticker = Attachment(
      id: 'sticker-1',
      kind: 'image',
      name: 'sticker.png',
      mime: 'image/png',
      size: 1024,
      duration: 0,
      url: '/api/files/sticker-1',
    );

    await AppProfile.instance.applyRemote(
      nickname: '旅行家',
      avatarUrl: '',
      stickers: [sticker],
    );

    expect(AppProfile.instance.stickers, hasLength(1));
    expect(AppProfile.instance.stickers.single.id, 'sticker-1');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile.stickers'), contains('sticker.png'));
  });

  test('云端没带表情包字段时不会清空本地表情包', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile.stickers'), isNotNull);

    await AppProfile.instance.applyRemote(nickname: '旅行家', avatarUrl: '');

    expect(AppProfile.instance.stickers, hasLength(1));
  });

  test('删除表情包会写入本地空列表', () async {
    await AppProfile.instance.saveStickers([]);

    expect(AppProfile.instance.stickers, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile.stickers'), '[]');
  });
}
