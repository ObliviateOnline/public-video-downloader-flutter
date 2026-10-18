import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VideoDownloaderApp());
}

class VideoDownloaderApp extends StatelessWidget {
  const VideoDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '公开视频下载器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff6750a4),
        brightness: Brightness.light,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: const DownloaderPage(),
    );
  }
}

class VideoInfo {
  const VideoInfo({
    required this.title,
    required this.uploader,
    required this.duration,
    required this.formats,
    required this.raw,
  });

  final String title;
  final String uploader;
  final String duration;
  final List<QualityOption> formats;
  final Map<String, dynamic> raw;

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    final formats = <QualityOption>[];
    final heights = <int>{};
    for (final item in (json['formats'] as List<dynamic>? ?? const [])) {
      if (item is! Map<String, dynamic>) continue;
      if (item['vcodec'] == null || item['vcodec'] == 'none') continue;
      final height = (item['height'] as num?)?.toInt() ?? 0;
      if (height > 0) heights.add(height);
    }
    formats.add(const QualityOption(
      label: '自动最佳（音视频合并）',
      selector: 'bestvideo*+bestaudio/best',
    ));
    final sorted = heights.toList()..sort((a, b) => b.compareTo(a));
    for (final height in sorted.take(6)) {
      formats.add(QualityOption(
        label: '最高 ${height}p（音视频合并）',
        selector: 'bestvideo[height<=$height]+bestaudio/best[height<=$height]',
      ));
    }
    formats.add(const QualityOption(
      label: '最佳单文件（兼容模式）',
      selector: 'best',
    ));
    return VideoInfo(
      title: (json['title'] ?? '未命名').toString(),
      uploader: (json['uploader'] ?? json['channel'] ?? '未知').toString(),
      duration: _formatDuration(json['duration']),
      formats: formats,
      raw: json,
    );
  }
}

class QualityOption {
  const QualityOption({required this.label, required this.selector});

  final String label;
  final String selector;
}

class DownloadService {
  Process? _process;

  Future<String> _resourcePath(String name) async {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$executableDir\\data\\flutter_assets\\resources\\$name',
      '$executableDir\\resources\\$name',
      '${Directory.current.path}\\resources\\$name',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    throw StateError('找不到内置资源：$name');
  }

  Future<String> _ytDlpPath() => _resourcePath('yt-dlp.exe');

  Future<VideoInfo> inspect(String url) async {
    final executable = await _ytDlpPath();
    final result = await Process.run(executable, [
      '--dump-single-json',
      '--no-playlist',
      '--no-warnings',
      '--windows-filenames',
      url,
    ], runInShell: false);
    if (result.exitCode != 0) {
      throw Exception(_cleanProcessError(result.stderr.toString()));
    }
    final output = result.stdout.toString().trim();
    final start = output.indexOf('{');
    final end = output.lastIndexOf('}');
    if (start < 0 || end <= start) throw Exception('没有解析到视频信息。');
    return VideoInfo.fromJson(
      jsonDecode(output.substring(start, end + 1)) as Map<String, dynamic>,
    );
  }

  Future<void> download({
    required String url,
    required QualityOption quality,
    required String directory,
    required void Function(double progress, String message) onProgress,
    required void Function(String line) onLog,
  }) async {
    final executable = await _ytDlpPath();
    final ffmpeg = await _resourcePath('ffmpeg.exe');
    final output = '$directory\\%(title).150s [%(id)s].%(ext)s';
    final args = <String>[
      '--newline',
      '--no-playlist',
      '--windows-filenames',
      '--continuedl',
      '--retries',
      '3',
      '--fragment-retries',
      '3',
      '--format',
      quality.selector,
      '--merge-output-format',
      'mp4',
      '--ffmpeg-location',
      ffmpeg,
      '--output',
      output,
      url,
    ];
    _process = await Process.start(executable, args, runInShell: false);
    final stdout = _process!.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final stderr = _process!.stderr.transform(utf8.decoder).transform(const LineSplitter());
    final futures = <Future<void>>[];
    futures.add(stdout.forEach((line) {
      onLog(line);
      final match = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
      if (match != null) {
        final value = double.tryParse(match.group(1)!) ?? 0;
        onProgress(value / 100, line.trim());
      } else if (line.contains('[Merger]')) {
        onProgress(1, '正在合并音视频……');
      }
    }));
    futures.add(stderr.forEach((line) {
      if (line.trim().isNotEmpty) onLog(line);
    }));
    await Future.wait(futures);
    final exitCode = await _process!.exitCode;
    _process = null;
    if (exitCode != 0) throw Exception('下载失败（退出码 $exitCode）。');
    onProgress(1, '下载完成');
  }

  Future<void> cancel() async {
    final process = _process;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
      _process = null;
    }
  }

  String _cleanProcessError(String value) {
    final lines = value.trim().split(RegExp(r'\r?\n'));
    return lines.where((line) => line.trim().isNotEmpty).take(4).join('\n');
  }
}

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final _urlController = TextEditingController();
  final _directoryController = TextEditingController();
  final _service = DownloadService();
  final _logs = <String>[];
  VideoInfo? _info;
  QualityOption? _quality;
  bool _busy = false;
  double _progress = 0;
  String _status = '就绪';

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['USERPROFILE'] ?? '';
    _directoryController.text = '$home\\Downloads';
    _addLog('程序已启动。请粘贴公开视频链接。');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _directoryController.dispose();
    super.dispose();
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _logs.add(line);
      if (_logs.length > 300) _logs.removeAt(0);
    });
  }

  Future<void> _inspect() async {
    final url = _urlController.text.trim();
    final parsed = Uri.tryParse(url);
    if (parsed == null || !{'http', 'https'}.contains(parsed.scheme)) {
      _show('请输入以 http:// 或 https:// 开头的链接。');
      return;
    }
    setState(() {
      _busy = true;
      _info = null;
      _progress = 0;
      _status = '正在解析……';
    });
    _addLog('开始解析：$url');
    try {
      final info = await _service.inspect(url);
      if (!mounted) return;
      setState(() {
        _info = info;
        _quality = info.formats.first;
        _busy = false;
        _status = '解析完成';
      });
      _addLog('解析成功：${info.title}');
    } catch (error) {
      _setError('解析失败：$error');
    }
  }

  Future<void> _chooseDirectory() async {
    final script = r'''Add-Type -AssemblyName System.Windows.Forms; $dialog = New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.Description = '选择视频保存目录'; if ($dialog.ShowDialog() -eq 'OK') { $dialog.SelectedPath }''';
    final result = await Process.run('powershell.exe', ['-NoProfile', '-Command', script]);
    final path = result.stdout.toString().trim();
    if (path.isNotEmpty) _directoryController.text = path;
  }

  Future<void> _download() async {
    final info = _info;
    final quality = _quality;
    final url = _urlController.text.trim();
    final directory = _directoryController.text.trim();
    if (info == null || quality == null || directory.isEmpty) return;
    await Directory(directory).create(recursive: true);
    setState(() {
      _busy = true;
      _progress = 0;
      _status = '准备下载……';
    });
    _addLog('开始下载：${quality.label}');
    _addLog('保存目录：$directory');
    try {
      await _service.download(
        url: url,
        quality: quality,
        directory: directory,
        onProgress: (progress, message) {
          if (!mounted) return;
          setState(() {
            _progress = progress.clamp(0, 1);
            _status = message;
          });
        },
        onLog: _addLog,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '下载完成';
        });
        _show('视频已保存到：\n$directory');
      }
    } catch (error) {
      _setError('下载失败：$error');
    }
  }

  Future<void> _cancel() async {
    await _service.cancel();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '已取消';
    });
    _addLog('下载已取消。');
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '发生错误';
    });
    _addLog(message);
    _show(message);
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _platform(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.contains('bilibili') || host.endsWith('b23.tv')) return '哔哩哔哩';
    if (host.contains('douyin') || host.contains('iesdouyin')) return '抖音';
    if (host.contains('weixin.qq.com')) return '微信视频号';
    return '自动识别站点';
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: 0,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Icon(Icons.download_rounded, size: 30),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library),
                  label: Text('下载'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('设置'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('公开视频下载器', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text('Flutter Windows 版', style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 22),
                    _buildUrlRow(),
                    const SizedBox(height: 14),
                    _buildDirectoryRow(),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 5, child: _buildInfoCard(info)),
                          const SizedBox(width: 16),
                          Expanded(flex: 4, child: _buildLogCard()),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildProgress(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUrlRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _urlController,
            enabled: !_busy,
            onSubmitted: (_) => _inspect(),
            decoration: InputDecoration(
              labelText: '视频链接',
              hintText: '粘贴 B 站、抖音等公开视频链接',
              prefixIcon: const Icon(Icons.link),
              suffixText: _platform(_urlController.text),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _inspect,
          icon: const Icon(Icons.search),
          label: const Text('解析信息'),
        ),
      ],
    );
  }

  Widget _buildDirectoryRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _directoryController,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '保存目录',
              prefixIcon: Icon(Icons.folder_outlined),
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _chooseDirectory,
          icon: const Icon(Icons.folder_open),
          label: const Text('选择目录'),
        ),
      ],
    );
  }

  Widget _buildInfoCard(VideoInfo? info) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: info == null
            ? const Center(child: Text('解析后将在这里显示视频信息'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('视频信息', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  Text(info.title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  Text('作者：${info.uploader}\n时长：${info.duration}'),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<QualityOption>(
                    initialValue: _quality,
                    decoration: const InputDecoration(labelText: '下载画质'),
                    items: info.formats.map((item) {
                      return DropdownMenuItem(value: item, child: Text(item.label));
                    }).toList(),
                    onChanged: _busy ? null : (value) => setState(() => _quality = value),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? _cancel : _download,
                      icon: Icon(_busy ? Icons.stop_circle_outlined : Icons.download),
                      label: Text(_busy ? '取消当前任务' : '开始下载'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('运行日志', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: const Color(0xfff5f3f7),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(_logs.join('\n'), style: const TextStyle(fontSize: 12, height: 1.35)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: LinearProgressIndicator(value: _progress == 0 ? null : _progress)),
            const SizedBox(width: 14),
            SizedBox(width: 260, child: Text(_status, overflow: TextOverflow.ellipsis)),
          ],
        ),
        const SizedBox(height: 8),
        const Text('仅下载公开且你有权保存的内容；不处理登录、付费、DRM、验证码或平台安全限制。'),
      ],
    );
  }
}

String _formatDuration(dynamic value) {
  final seconds = (value is num) ? value.toInt() : 0;
  if (seconds <= 0) return '未知';
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$secs' : '$minutes:$secs';
}
