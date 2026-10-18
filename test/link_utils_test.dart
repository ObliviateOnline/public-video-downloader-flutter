import 'package:flutter_test/flutter_test.dart';

import 'package:public_video_downloader/link_utils.dart';

void main() {
  test('extracts a full URL from copied share text', () {
    expect(
      extractSharedUrl('复制这段内容，打开抖音搜索，https://v.douyin.com/abc/。'),
      'https://v.douyin.com/abc/',
    );
  });

  test('extracts the real Douyin URL from a complete share message', () {
    const copied =
        '0.58 复制打开抖音，看看【记得好好睡觉的作品】星奇摇怎么又又又杀回来了！ '
        '#星奇摇 #ai跳... https://v.douyin.com/EBLpFoU8vxU/ '
        'g@B.Tl :6pm 02/24 ebA:/';
    expect(extractSharedUrl(copied), 'https://v.douyin.com/EBLpFoU8vxU/');
  });

  test('adds https to a bare supported share URL', () {
    expect(extractSharedUrl('打开链接：v.douyin.com/abc/'), 'https://v.douyin.com/abc/');
    expect(
      extractSharedUrl('B站：www.bilibili.com/video/BV1abc/'),
      'https://www.bilibili.com/video/BV1abc/',
    );
  });
}
