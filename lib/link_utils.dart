const _supportedBareHostPattern =
    r'(?:www\.)?(?:v\.douyin\.com|douyin\.com|iesdouyin\.com|bilibili\.com|b23\.tv|weixin\.qq\.com)';

final _fullUrlPattern = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);
final _bareUrlPattern = RegExp(
  '((?:$_supportedBareHostPattern)/[^\\s<>"\']+)',
  caseSensitive: false,
);

/// Extract a URL from copied share text and add https:// when it is omitted.
String extractSharedUrl(String input) {
  final text = input.trim().replaceAll('&amp;', '&');
  final full = _fullUrlPattern.firstMatch(text)?.group(0);
  final bare = _bareUrlPattern.firstMatch(text)?.group(1);
  final value = full ?? bare;
  if (value == null) return text;
  final normalized = value.replaceFirst(RegExp(r'[，。；、）】》>.,;:!?\)\]}]+$'), '');
  return normalized.startsWith(RegExp(r'https?://', caseSensitive: false))
      ? normalized
      : 'https://$normalized';
}
