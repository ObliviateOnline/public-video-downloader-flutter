import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'link_utils.dart';

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
      label: '兼容模式：最佳单文件（不需要 FFmpeg）',
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

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

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

  Future<String> prepareDouyinCookies(String url) async {
    if (!Platform.isWindows) throw StateError('自动获取抖音会话仅支持 Windows。');
    final edge = await _findEdge();
    final profile = await Directory.systemTemp.createTemp('public-video-edge-');
    final port = 9340 + DateTime.now().millisecondsSinceEpoch % 500;
    final edgeProcess = await Process.start(edge, [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=$port',
      '--user-data-dir=${profile.path}',
      url,
    ], runInShell: false);
    WebSocketChannel? channel;
    try {
      // /json/version is the browser-level socket. Page and Network commands
      // must use the socket belonging to an actual page target.
      final websocketUrl = await _findPageWebSocket(port);
      if (websocketUrl == null) throw StateError('临时浏览器会话启动失败。');
      channel = WebSocketChannel.connect(Uri.parse(websocketUrl));
      await channel.ready;
      var nextId = 0;
      var cookiesId = -1;
      final cookiesCompleter = Completer<List<dynamic>>();
      channel.stream.listen((message) {
        try {
          final text = message is String ? message : utf8.decode(message as List<int>);
          final data = jsonDecode(text) as Map<String, dynamic>;
          final result = data['result'];
          if (data['error'] is Map<String, dynamic> && !cookiesCompleter.isCompleted) {
            cookiesCompleter.completeError(StateError('临时浏览器返回 CDP 错误。'));
            return;
          }
          if (data['id'] == cookiesId && !cookiesCompleter.isCompleted) {
            final payload = result as Map<String, dynamic>?;
            cookiesCompleter.complete(payload?['cookies'] as List<dynamic>? ?? const []);
          }
        } catch (_) {}
      });
      channel.sink.add(jsonEncode({'id': ++nextId, 'method': 'Network.enable'}));
      channel.sink.add(jsonEncode({'id': ++nextId, 'method': 'Page.navigate', 'params': {'url': url}}));
      await Future<void>.delayed(const Duration(seconds: 6));
      cookiesId = ++nextId;
      channel.sink.add(jsonEncode({'id': cookiesId, 'method': 'Network.getAllCookies'}));
      final cookies = await cookiesCompleter.future.timeout(const Duration(seconds: 12));
      if (cookies.isEmpty) throw StateError('临时浏览器没有获取到抖音 Cookie。');
      final cookieFile = File('${profile.path}\\cookies.txt');
      await cookieFile.writeAsString(_netscapeCookies(cookies));
      return cookieFile.path;
    } finally {
      await channel?.sink.close();
      edgeProcess.kill();
      await edgeProcess.exitCode;
    }
  }

  Future<String?> _findPageWebSocket(int port) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        final response = await http.get(Uri.parse('http://127.0.0.1:$port/json/list'));
        if (response.statusCode != 200) continue;
        final targets = jsonDecode(response.body);
        if (targets is! List) continue;
        for (final target in targets) {
          if (target is Map<String, dynamic> && target['type'] == 'page') {
            final value = target['webSocketDebuggerUrl'];
            if (value is String && value.isNotEmpty) return value;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String> _findEdge() async {
    const candidates = [
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    final result = await Process.run('where.exe', ['msedge.exe']);
    final path = result.stdout.toString().split(RegExp(r'\r?\n')).firstWhere(
      (line) => line.trim().isNotEmpty,
      orElse: () => '',
    ).trim();
    if (path.isNotEmpty && await File(path).exists()) return path;
    throw StateError('找不到 Microsoft Edge，无法自动获取抖音会话。');
  }

  String _netscapeCookies(List<dynamic> cookies) {
    final lines = <String>['# Netscape HTTP Cookie File'];
    for (final item in cookies) {
      if (item is! Map<String, dynamic>) continue;
      final domain = (item['domain'] ?? '').toString();
      final path = (item['path'] ?? '/').toString();
      final secure = item['secure'] == true ? 'TRUE' : 'FALSE';
      final expires = ((item['expires'] as num?)?.toInt() ?? 0).toString();
      final name = (item['name'] ?? '').toString();
      final value = (item['value'] ?? '').toString();
      if (domain.isNotEmpty && name.isNotEmpty) {
        lines.add('$domain\tTRUE\t$path\t$secure\t$expires\t$name\t$value');
      }
    }
    return '${lines.join('\n')}\n';
  }

  Future<VideoInfo> inspect(String url, {String? browser, String? cookiesFile, String? serverUrl}) async {
    if (isMobile) return _inspectRemote(url, serverUrl);
    final executable = await _ytDlpPath();
    final args = <String>[
      '--dump-single-json',
      '--no-playlist',
      '--no-warnings',
      '--windows-filenames',
    ];
    if (cookiesFile != null && cookiesFile.isNotEmpty) {
      args.addAll(['--cookies', cookiesFile]);
    } else if (browser != null && browser.isNotEmpty && browser != 'auto') {
      args.addAll(['--cookies-from-browser', browser]);
    }
    args.add(url);
    final result = await Process.run(executable, args, runInShell: false);
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

  Future<VideoInfo> _inspectRemote(String url, String? serverUrl) async {
    final base = _normalizeServerUrl(serverUrl);
    final response = await http.post(
      Uri.parse('$base/api/info'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'url': url}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_cleanProcessError(response.body));
    }
    return VideoInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<String?> download({
    required String url,
    required QualityOption quality,
    required String directory,
    String? browser,
    String? cookiesFile,
    String? serverUrl,
    required String suggestedName,
    required void Function(double progress, String message) onProgress,
    required void Function(String line) onLog,
  }) async {
    if (isMobile) {
      return _downloadRemote(
        url: url,
        quality: quality,
        serverUrl: serverUrl,
        suggestedName: suggestedName,
        onProgress: onProgress,
        onLog: onLog,
      );
    }
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
    ];
    if (cookiesFile != null && cookiesFile.isNotEmpty) {
      args.addAll(['--cookies', cookiesFile]);
    } else if (browser != null && browser.isNotEmpty && browser != 'auto') {
      args.addAll(['--cookies-from-browser', browser]);
    }
    args.add(url);
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
    return null;
  }

  Future<String> _downloadRemote({
    required String url,
    required QualityOption quality,
    required String? serverUrl,
    required String suggestedName,
    required void Function(double progress, String message) onProgress,
    required void Function(String line) onLog,
  }) async {
    final base = _normalizeServerUrl(serverUrl);
    final client = http.Client();
    try {
      onLog('正在请求下载服务……');
      final request = http.Request('POST', Uri.parse('$base/api/download'))
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({'url': url, 'format': quality.selector});
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(_cleanProcessError(await response.stream.bytesToString()));
      }
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/${_safeFileName(suggestedName)}.mp4');
      final sink = file.openWrite();
      var received = 0;
      final total = response.contentLength ?? 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        final progress = total > 0 ? received / total : 0.0;
        onProgress(
          progress,
          total > 0 ? '保存到手机 ${(progress * 100).toStringAsFixed(1)}%' : '正在保存到手机……',
        );
      }
      await sink.close();
      onLog('文件已保存到应用文件目录：${file.path}');
      onProgress(1, '下载完成');
      return file.path;
    } finally {
      client.close();
    }
  }

  String _normalizeServerUrl(String? value) {
    final base = value?.trim() ?? '';
    if (base.isEmpty) throw Exception('请先填写下载服务地址。');
    return base.replaceFirst(RegExp(r'/+$'), '');
  }

  String _safeFileName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
    if (cleaned.isEmpty) return 'video';
    return cleaned.substring(0, cleaned.length > 100 ? 100 : cleaned.length);
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

String _friendlyError(Object error) {
  final message = error.toString();
  if (message.contains('Fresh cookies')) {
    return '抖音需要新鲜的浏览器会话。请先在浏览器打开该视频，再关闭浏览器，选择对应浏览器会话后重新解析。';
  }
  if (message.contains('Failed to decrypt with DPAPI')) {
    return '浏览器 Cookie 解密失败。请完全退出浏览器后重试；如果仍失败，请选择导出的 cookies.txt 文件。';
  }
  if (message.contains('Could not copy Chrome cookie database')) {
    return '浏览器仍在后台运行，Cookie 数据库无法读取。请完全退出 Chrome/Edge，或选择导出的 cookies.txt 文件。';
  }
  if (message.contains('微信视频号') || message.contains('WeChat')) {
    return '微信视频号目前没有稳定的 yt-dlp 专用解析器，这类分享链接可能暂时无法下载。';
  }
  return message;
}

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final _urlController = TextEditingController();
  final _directoryController = TextEditingController();
  final _serverController = TextEditingController();
  final _service = DownloadService();
  final _logs = <String>[];
  VideoInfo? _info;
  QualityOption? _quality;
  bool _busy = false;
  double _progress = 0;
  String _status = '就绪';
  String _browser = 'auto';
  String _cookiesFile = '';
  bool _cookiesFileManual = false;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['USERPROFILE'] ?? '';
    _directoryController.text = Platform.isWindows ? '$home\\Downloads' : '下载到应用文件目录';
    _serverController.text = Platform.isAndroid ? 'http://10.0.2.2:8000' : 'http://127.0.0.1:8000';
    _addLog('程序已启动。请粘贴公开视频链接。');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _directoryController.dispose();
    _serverController.dispose();
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
    final url = extractSharedUrl(_urlController.text);
    final parsed = Uri.tryParse(url);
    if (parsed == null || !{'http', 'https'}.contains(parsed.scheme)) {
      _show('没有识别到有效链接。请直接粘贴整段分享文案，或包含 v.douyin.com / b23.tv 的内容。');
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
      var cookiesFile = _cookiesFile;
      if (Platform.isWindows && _isDouyinUrl(url) && !_cookiesFileManual && _browser == 'auto') {
        _addLog('正在自动启动临时浏览器获取抖音会话……');
        cookiesFile = await _service.prepareDouyinCookies(url);
        if (mounted) {
          setState(() {
            _cookiesFile = cookiesFile;
            _cookiesFileManual = false;
          });
        }
        _addLog('已自动获取抖音会话。');
      }
      final info = await _service.inspect(
        url,
        browser: _browser,
        cookiesFile: cookiesFile,
        serverUrl: _serverController.text,
      );
      if (!mounted) return;
      setState(() {
        _info = info;
        _quality = info.formats.first;
        _busy = false;
        _status = '解析完成';
      });
      _addLog('解析成功：${info.title}');
    } catch (error) {
      _setError('解析失败：${_friendlyError(error)}');
    }
  }

  Future<void> _chooseDirectory() async {
    if (!Platform.isWindows) return;
    final script = r'''Add-Type -AssemblyName System.Windows.Forms; $dialog = New-Object System.Windows.Forms.FolderBrowserDialog; $dialog.Description = '选择视频保存目录'; if ($dialog.ShowDialog() -eq 'OK') { $dialog.SelectedPath }''';
    final result = await Process.run('powershell.exe', ['-NoProfile', '-Command', script]);
    final path = result.stdout.toString().trim();
    if (path.isNotEmpty) _directoryController.text = path;
  }

  Future<void> _chooseCookiesFile() async {
    if (!Platform.isWindows) return;
    const script = r'''Add-Type -AssemblyName System.Windows.Forms; $dialog = New-Object System.Windows.Forms.OpenFileDialog; $dialog.Title = '选择 cookies.txt'; $dialog.Filter = 'Cookie 文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'; if ($dialog.ShowDialog() -eq 'OK') { $dialog.FileName }''';
    final result = await Process.run('powershell.exe', ['-NoProfile', '-Command', script]);
    final path = result.stdout.toString().trim();
    if (path.isNotEmpty && mounted) {
      setState(() {
        _cookiesFile = path;
        _cookiesFileManual = true;
        _browser = '';
      });
      _addLog('已选择 Cookie 文件（不会把 Cookie 写入日志）。');
    }
  }

  Future<void> _download() async {
    final info = _info;
    final quality = _quality;
    final url = extractSharedUrl(_urlController.text);
    final directory = _directoryController.text.trim();
    if (info == null || quality == null || directory.isEmpty) return;
    if (Platform.isWindows) {
      await Directory(directory).create(recursive: true);
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = '准备下载……';
    });
    _addLog('开始下载：${quality.label}');
    _addLog('保存目录：$directory');
    try {
      final savedPath = await _service.download(
        url: url,
        quality: quality,
        directory: directory,
        browser: _browser,
        cookiesFile: _cookiesFile,
        serverUrl: _serverController.text,
        suggestedName: info.title,
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
        if (savedPath != null && _service.isMobile) {
          await SharePlus.instance.share(ShareParams(files: [XFile(savedPath)]));
          _show('视频已下载，请在系统分享面板中保存或发送。');
        } else {
          _show('视频已保存到：\n$directory');
        }
      }
    } catch (error) {
      _setError('下载失败：${_friendlyError(error)}');
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
    if (host.contains('weixin.qq.com')) return '微信视频号（实验性）';
    return '自动识别站点';
  }

  bool _isDouyinUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.contains('douyin') || host.contains('iesdouyin');
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (!compact) NavigationRail(
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
            if (!compact) const VerticalDivider(width: 1),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(compact ? 14 : 28, 20, compact ? 14 : 28, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('公开视频下载器', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      Platform.isWindows ? 'Flutter Windows 版' : 'Flutter 移动版',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 22),
                    _buildUrlRow(),
                    const SizedBox(height: 14),
                    _buildDirectoryRow(),
                    const SizedBox(height: 14),
                    if (Platform.isWindows) _buildBrowserRow(),
                    if (!Platform.isWindows) _buildServerRow(),
                    const SizedBox(height: 16),
                    Expanded(child: _buildCards(info)),
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

  Widget _buildCards(VideoInfo? info) {
    if (MediaQuery.sizeOf(context).width < 700) {
      return Column(
        children: [
          Expanded(flex: 5, child: _buildInfoCard(info)),
          const SizedBox(height: 12),
          Expanded(flex: 4, child: _buildLogCard()),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 5, child: _buildInfoCard(info)),
        const SizedBox(width: 16),
        Expanded(flex: 4, child: _buildLogCard()),
      ],
    );
  }

  Widget _buildUrlRow() {
    final field = TextField(
      controller: _urlController,
      enabled: !_busy,
      onSubmitted: (_) => _inspect(),
      decoration: InputDecoration(
        labelText: '视频链接',
        hintText: '粘贴分享文字或 B 站、抖音视频链接',
        prefixIcon: const Icon(Icons.link),
        suffixText: _platform(_urlController.text),
      ),
    );
    final button = FilledButton.icon(
      onPressed: _busy ? null : _inspect,
      icon: const Icon(Icons.search),
      label: const Text('解析信息'),
    );
    if (MediaQuery.sizeOf(context).width < 700) {
      return Column(children: [field, const SizedBox(height: 10), SizedBox(width: double.infinity, child: button)]);
    }
    return Row(children: [Expanded(child: field), const SizedBox(width: 12), button]);
  }

  Widget _buildDirectoryRow() {
    final field = TextField(
      controller: _directoryController,
      enabled: !_busy && Platform.isWindows,
      decoration: const InputDecoration(
        labelText: '保存目录',
        prefixIcon: Icon(Icons.folder_outlined),
      ),
    );
    final button = OutlinedButton.icon(
      onPressed: _busy || !Platform.isWindows ? null : _chooseDirectory,
      icon: const Icon(Icons.folder_open),
      label: const Text('选择目录'),
    );
    if (MediaQuery.sizeOf(context).width < 700) {
      return Column(children: [field, if (Platform.isWindows) const SizedBox(height: 10), if (Platform.isWindows) SizedBox(width: double.infinity, child: button)]);
    }
    return Row(children: [Expanded(child: field), const SizedBox(width: 12), if (Platform.isWindows) button]);
  }

  Widget _buildBrowserRow() {
    final browserPicker = DropdownButtonFormField<String>(
            initialValue: _browser,
            decoration: const InputDecoration(
              labelText: '浏览器会话（抖音需要）',
              prefixIcon: Icon(Icons.web),
            ),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('自动获取（推荐）')),
              DropdownMenuItem(value: '', child: Text('不使用浏览器会话')),
              DropdownMenuItem(value: 'chrome', child: Text('Chrome')),
              DropdownMenuItem(value: 'edge', child: Text('Microsoft Edge')),
              DropdownMenuItem(value: 'firefox', child: Text('Firefox')),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _browser = value ?? '';
                    _cookiesFile = '';
                    _cookiesFileManual = false;
                  }),
          );
    final cookieButton = OutlinedButton.icon(
      onPressed: _busy ? null : _chooseCookiesFile,
      icon: const Icon(Icons.key_outlined),
      label: Text(_cookiesFile.isEmpty ? '选择 cookies.txt' : '已选择 Cookie 文件'),
    );
    final note = Text(
      _cookiesFile.isEmpty
          ? (_browser == 'auto'
              ? '解析抖音时会自动启动临时 Edge 会话，不影响你正在使用的浏览器。'
              : '浏览器必须完全退出；如果仍然报 Cookie 解密错误，请选择 cookies.txt。')
          : '当前优先使用 cookies.txt，已忽略浏览器会话。',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [Expanded(child: browserPicker), const SizedBox(width: 10), cookieButton]),
        const SizedBox(height: 5),
        note,
      ],
    );
  }

  Widget _buildServerRow() {
    final field = TextField(
      controller: _serverController,
      enabled: !_busy,
      decoration: const InputDecoration(
        labelText: '下载服务地址',
        prefixIcon: Icon(Icons.cloud_outlined),
        hintText: '例如 http://192.168.1.20:8000',
      ),
    );
    const note = Text('手机与电脑需在同一网络，或填写已部署的 HTTPS 服务地址。');
    if (MediaQuery.sizeOf(context).width < 700) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [field, const SizedBox(height: 6), note]);
    }
    return Row(children: [Expanded(child: field), const SizedBox(width: 12), const Expanded(child: note)]);
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
                  const SizedBox(height: 8),
                  const Text(
                    '高画质选项会合并独立音视频；选择“兼容模式”时优先使用平台提供的单文件视频。',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
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
