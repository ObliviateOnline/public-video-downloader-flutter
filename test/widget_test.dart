// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:public_video_downloader/main.dart';

void main() {
  testWidgets('shows downloader shell', (WidgetTester tester) async {
    await tester.pumpWidget(const VideoDownloaderApp());

    expect(find.text('公开视频下载器'), findsOneWidget);
    expect(find.text('解析信息'), findsOneWidget);
    expect(find.text('保存目录'), findsOneWidget);
  });
}
