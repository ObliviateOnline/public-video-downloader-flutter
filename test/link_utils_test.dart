import 'package:flutter_test/flutter_test.dart';

import 'package:public_video_downloader/link_utils.dart';

void main() {
  test('extracts a full URL from copied share text', () {
    expect(
      extractSharedUrl('复制这段内容，打开抖音搜索，https://v.douyin.com/abc/。'),
      'https://v.douyin.com/abc/',
    );
  });

  test('adds https to a bare supported share URL', () {
    expect(extractSharedUrl('打开链接：v.douyin.com/abc/'), 'https://v.douyin.com/abc/');
    expect(
      extractSharedUrl('B站：www.bilibili.com/video/BV1abc/'),
      'https://www.bilibili.com/video/BV1abc/',
    );
  });
}
