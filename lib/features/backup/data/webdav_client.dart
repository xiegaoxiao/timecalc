import 'dart:convert';

import 'package:http/http.dart' as http;

/// WebDAV 交互异常：携带用户可读的原因与可选 HTTP 状态码。
///
/// 网络层 / 协议层错误统一转换为 [WebDavException]，UI 用 `on Exception`
/// 即可捕获并展示，不会泄漏原始 socket/HttpException 细节（NFR-3 隐私：
/// 错误文案不含 URL 与凭据）。
class WebDavException implements Exception {
  const WebDavException(this.message, {this.statusCode});

  final String message;

  /// HTTP 状态码；网络错误/解析错误时为 null。
  final int? statusCode;

  @override
  String toString() => message;
}

/// WebDAV 认证失败（HTTP 401）：用户名或密码错误。
class WebDavAuthException extends WebDavException {
  const WebDavAuthException([String? message])
      : super(message ?? 'WebDAV 认证失败（401）：请检查用户名与密码');
}

/// WebDAV 单目录项（PROPFIND 解析结果）。
class WebDavFileInfo {
  const WebDavFileInfo({
    required this.href,
    required this.isDirectory,
    required this.size,
    this.modifiedAt,
  });

  /// 服务器返回的资源路径（已解码，相对或绝对均可，取文件名时用末段）。
  final String href;

  final bool isDirectory;

  /// 资源大小（字节）；服务器未返回时 0。
  final int size;

  /// 最后修改时间（UTC）；服务器未返回时为 null。
  final DateTime? modifiedAt;
}

/// WebDAV 薄客户端（自研，M8）。
///
/// 只实现 TimeCalc 备份所需的子集：MKCOL（建目录，幂等）、PUT（上传）、
/// PROPFIND（列目录）、GET（下载）、DELETE（删除），Basic Auth 认证。
/// 不引入第三方 WebDAV 库（S0 依赖登记：无新增网络库；http 包提升为
/// 直接依赖）。
///
/// 路径约定：相对路径按 `/` 分段逐段 percent-encode（非 ASCII 目录名
/// 安全），拼接在服务器地址之后。服务器行为差异做宽容处理：
/// MKCOL 返回 405/301 视为目录已存在。
class WebDavClient {
  WebDavClient({
    required this.client,
    required String baseUrl,
    this.username,
    this.password,
    this.timeout = const Duration(seconds: 20),
  }) : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), '');

  final http.Client client;
  final String _baseUrl;
  final String? username;
  final String? password;
  final Duration timeout;

  /// 相对路径 → 完整 URL 文本（逐段编码，base 原样保留）。
  String href(String path) {
    final encoded =
        path.split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent).join('/');
    return '$_baseUrl/$encoded';
  }

  /// 确保目录存在（沿完整 URL 路径逐级 MKCOL，幂等）。
  ///
  /// RFC 4918 的 MKCOL 无法一次创建中间目录缺失的多级路径（返回 409）：
  /// 例如 baseUrl 为 `https://host/dav/timecalc`、path 为 `webdav_auto` 时，
  /// 直接 MKCOL `.../timecalc/webdav_auto` 会因 `timecalc` 不存在而 409
  /// （坚果云/NAS 等合规服务器行为）。这里把 baseUrl 路径段与相对 path 段
  /// 合并，从 baseUrl 第二段起逐级 MKCOL：
  /// - 第一个路径段是用户的认证 WebDAV 根（如 `/dav`），必然存在且不可
  ///   创建（MKCOL 返回 401/403），跳过不试；
  /// - 其余段逐级创建，每段 2xx/405/409/301/302 视为该段已就绪；
  /// - 目录真实可用性仍由随后的 PROPFIND/PUT 兜底验证（NFR-2）。
  Future<void> ensureFolder(String path) async {
    final baseUri = Uri.parse(_baseUrl);
    final segments = [
      ...baseUri.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ];

    var current = baseUri.origin;
    for (var i = 0; i < segments.length; i++) {
      current = '$current/${Uri.encodeComponent(segments[i])}';
      if (i == 0) continue; // WebDAV 根：跳过，不尝试创建。
      final response = await _sendUri('MKCOL', Uri.parse(current));
      if (_isOk(response) ||
          response.statusCode == 405 ||
          response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 409) {
        continue; // 创建成功或该段已存在/已就绪，尝试下一级。
      }
      throw _friendly('创建目录失败', response);
    }
  }

  /// 上传文件（PUT）。
  Future<void> upload(String path, List<int> bytes) async {
    final response = await _send('PUT', path, bodyBytes: bytes);
    if (!_isOk(response)) {
      throw _friendly('上传失败', response);
    }
  }

  /// 列目录（PROPFIND depth:1），返回目录项（不含目录本身）。
  ///
  /// 目录状态未就绪（服务器对不存在/刚创建的目录返回 409）时自动
  /// [ensureFolder] 后重试一次：这比直接报错对用户更友好，且最终仍以
  /// 真实 PROPFIND 结果为准（NFR-2：不掩盖真实错误）。
  Future<List<WebDavFileInfo>> list(String path) async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:">'
        '<D:prop>'
        '<D:resourcetype/>'
        '<D:getcontentlength/>'
        '<D:getlastmodified/>'
        '</D:prop>'
        '</D:propfind>';
    var response = await _send(
      'PROPFIND',
      path,
      bodyBytes: utf8.encode(body),
      extraHeaders: const {
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
    );
    // 409 = 目标状态冲突（部分服务器对「不存在的路径」或「刚创建但尚未
    // 就绪的目录」如此响应）：建目录后再查一次，避免把可用场景误判失败。
    if (response.statusCode == 409 && path.isNotEmpty) {
      await ensureFolder(path);
      response = await _send(
        'PROPFIND',
        path,
        bodyBytes: utf8.encode(body),
        extraHeaders: const {
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
      );
    }
    if (!_isOk(response) && response.statusCode != 207) {
      throw _friendly('读取目录失败', response);
    }
    return _parseMultistatus(utf8.decode(response.bodyBytes), basePath: path);
  }

  /// 下载文件（GET）。
  Future<List<int>> download(String path) async {
    final response = await _send('GET', path);
    if (!_isOk(response)) {
      throw _friendly('下载失败', response);
    }
    return response.bodyBytes;
  }

  /// 删除文件（DELETE；已不存在视为成功，幂等）。
  Future<void> delete(String path) async {
    final response = await _send('DELETE', path);
    if (_isOk(response) || response.statusCode == 404) return;
    throw _friendly('删除失败', response);
  }

  Future<http.Response> _send(
    String method,
    String path, {
    List<int>? bodyBytes,
    Map<String, String>? extraHeaders,
  }) {
    return _sendUri(
      method,
      Uri.parse(href(path)),
      bodyBytes: bodyBytes,
      extraHeaders: extraHeaders,
    );
  }

  Future<http.Response> _sendUri(
    String method,
    Uri uri, {
    List<int>? bodyBytes,
    Map<String, String>? extraHeaders,
  }) async {
    final request = http.Request(method, uri);
    request.headers['Authorization'] =
        'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    if (extraHeaders != null) request.headers.addAll(extraHeaders);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;

    try {
      final streamed = await client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      // 认证失败统一抛 WebDavAuthException（UI/测试据此给出可读提示）。
      if (response.statusCode == 401) {
        throw const WebDavAuthException();
      }
      return response;
    } on WebDavException {
      rethrow;
    } catch (error) {
      throw WebDavException('网络错误：${error.runtimeType}，请检查地址与网络');
    }
  }

  static bool _isOk(http.Response response) =>
      response.statusCode >= 200 && response.statusCode < 300;

  /// 给 HTTP 错误码配一句可读原因（不含 URL/凭据，NFR-3）。
  static WebDavException _friendly(String action, http.Response response) {
    final code = response.statusCode;
    final String reason;
    switch (code) {
      case 401:
        reason = '$action：认证失败（401），请检查用户名与密码';
      case 403:
        reason = '$action：无权限（403），请检查目录写权限';
      case 404:
        reason = '$action：路径不存在（404）';
      case 409:
        reason = '$action：目标已存在冲突（409）';
      case 507:
        reason = '$action：存储空间不足（507）';
      default:
        reason = '$action（HTTP $code）';
    }
    return WebDavException(reason, statusCode: code);
  }

  /// 解析 PROPFIND 的 `multistatus` XML。
  ///
  /// 用轻量正则而非 XML 解析器（避免引入 xml 依赖）：多命名空间前缀
  /// （`D:`/`d:`/`lp1:`/无前缀）一律容忍；`<response>` 块不嵌套。
  /// href 解码对原始中文等非法 percent-encoding 容错（回退原样）。
  static List<WebDavFileInfo> _parseMultistatus(String xml, {required String basePath}) {
    final responses = RegExp(
      r'<(?:[\w-]+:)?response\b[^>]*>([\s\S]*?)</(?:[\w-]+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);
    final normalizedBase = basePath.replaceFirst(RegExp(r'/$'), '');

    final result = <WebDavFileInfo>[];
    for (final match in responses) {
      final block = match.group(1) ?? '';
      final href = _firstTagContent(block, 'href');
      if (href == null) continue;
      String decodedHref;
      try {
        decodedHref = Uri.decodeComponent(href);
      } catch (_) {
        decodedHref = href; // 非法 percent-encoding 时按原样使用
      }
      // 跳过目录项本身（href 与请求路径一致或以目录斜杠结尾）。
      final trimmed = decodedHref.replaceFirst(RegExp(r'/$'), '');
      if (trimmed == normalizedBase) continue;
      final isDirectory = _hasCollection(block);
      if (isDirectory) continue; // 只列文件，目录项对备份无意义。

      final lengthText = _firstTagContent(block, 'getcontentlength');
      final modifiedText = _firstTagContent(block, 'getlastmodified');
      result.add(
        WebDavFileInfo(
          href: decodedHref,
          isDirectory: false,
          size: int.tryParse(lengthText ?? '') ?? 0,
          modifiedAt: modifiedText == null ? null : _tryParseHttpDate(modifiedText),
        ),
      );
    }
    return result;
  }

  static String? _firstTagContent(String block, String tag) {
    final match = RegExp(
      r'<(?:[\w-]+:)?' + RegExp.escape(tag) + r'\b[^>]*>([\s\S]*?)</(?:[\w-]+:)?' +
          RegExp.escape(tag) + r'>',
      caseSensitive: false,
    ).firstMatch(block);
    return match?.group(1)?.trim();
  }

  static bool _hasCollection(String block) =>
      RegExp(r'<(?:[\w-]+:)?collection\b[^>]*/?>', caseSensitive: false)
          .hasMatch(block);

  /// 月份英文缩写 → 数字（RFC1123 getlastmodified 解析）。
  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  /// 解析 WebDAV getlastmodified（RFC1123 为主，ISO8601 兜底）。
  ///
  /// 不引入 http_parser 依赖：备份列表的修改时间只用于排序展示，
  /// 解析失败返回 null 不影响功能。
  static DateTime? _tryParseHttpDate(String text) {
    final match = RegExp(
      r'^[A-Za-z]+, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(text);
    if (match != null) {
      final month = _months[match.group(2)!];
      if (month != null) {
        return DateTime.utc(
          int.parse(match.group(3)!),
          month,
          int.parse(match.group(1)!),
          int.parse(match.group(4)!),
          int.parse(match.group(5)!),
          int.parse(match.group(6)!),
        );
      }
    }
    return DateTime.tryParse(text);
  }
}
