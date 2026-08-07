import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:timecalc/features/backup/data/webdav_client.dart';

/// WebDAV 薄客户端测试（M8，FR-9.4）。
///
/// 全部走 MockClient，不触碰真实网络：
/// - MKCOL 幂等（201 创建 / 405 已存在）；
/// - PUT 上传与失败文案；
/// - PROPFIND 多态 XML 解析（D:/lp1:/无前缀命名空间，过滤目录项）；
/// - GET 下载 / DELETE 删除（404 幂等）；
/// - 401 认证失败 → WebDavAuthException；非 2xx → WebDavException；
/// - 路径逐段 percent-encode（中文/空格目录安全）；
/// - getlastmodified RFC1123 解析。
void main() {
  WebDavClient clientWith(MockClient mock) => WebDavClient(
        client: mock,
        baseUrl: 'https://dav.example.com/dav',
        username: 'alice',
        password: 'secret',
      );

  group('路径编码', () {
    test('中文/空格目录逐段 percent-encode', () {
      final client = clientWith(MockClient((_) async => http.Response('', 200)));
      expect(
        client.href('webdav_auto'),
        'https://dav.example.com/dav/webdav_auto',
      );
      expect(
        client.href('备份 目录/文件.timecalc'),
        contains('%E5%A4%87%E4%BB%BD'),
      );
    });

    test('baseUrl 末尾斜杠被规整', () {
      final client = WebDavClient(
        client: MockClient((_) async => http.Response('', 200)),
        baseUrl: 'https://dav.example.com/dav/',
        username: 'a',
        password: 'b',
      );
      expect(client.href('x'), 'https://dav.example.com/dav/x');
    });
  });

  group('ensureFolder', () {
    test('201 逐级创建成功（先建 baseUrl 路径段，再建目标）', () async {
      final requested = <String>[];
      final client = clientWith(MockClient((req) async {
        expect(req.method, 'MKCOL');
        expect(req.headers['Authorization'], startsWith('Basic '));
        requested.add(req.url.toString());
        return http.Response('', 201);
      }));
      await client.ensureFolder('webdav_auto');
      // baseUrl 含 /dav（认证根，跳过）：只建 dav/webdav_auto。
      expect(requested, ['https://dav.example.com/dav/webdav_auto']);
    });

    test('多级 baseUrl（/dav/timecalc）逐级创建直到目标（回归）', () async {
      // 用户地址带 /timecalc 时，父目录不存在导致 MKCOL 一次建两层返回 409：
      // ensureFolder 必须沿完整路径逐级创建。首个段（/dav 认证根）跳过，
      // 依次创建 timecalc → webdav_auto。
      final requested = <String>[];
      final client = WebDavClient(
        client: MockClient((req) async {
          expect(req.method, 'MKCOL');
          requested.add(req.url.toString());
          return http.Response('', 201);
        }),
        baseUrl: 'https://dav.jianguoyun.com/dav/timecalc',
        username: 'a',
        password: 'b',
      );
      await client.ensureFolder('webdav_auto');
      expect(requested, [
        'https://dav.jianguoyun.com/dav/timecalc',
        'https://dav.jianguoyun.com/dav/timecalc/webdav_auto',
      ]);
    });

    test('认证根段不尝试创建（根 MKCOL 403 不报错，回归）', () async {
      // 坚果云等对 MKCOL 用户 WebDAV 根（/dav）返回 403；ensureFolder
      // 必须跳过首个段，只在其余段上 MKCOL。
      final requested = <String>[];
      final client = WebDavClient(
        client: MockClient((req) async {
          requested.add(req.url.path);
          // 首个（且仅有的）请求是 webdav_auto，根从未被尝试。
          return http.Response('', 201);
        }),
        baseUrl: 'https://dav.jianguoyun.com/dav',
        username: 'a',
        password: 'b',
      );
      await client.ensureFolder('webdav_auto');
      expect(requested, ['/dav/webdav_auto']);
    });

    test('裸 host baseUrl（无认证根段）时目标目录即首段，必须创建（回归）', () async {
      // baseUrl 无路径（如 https://dav.example.com）时没有认证根可跳过：
      // webdav_auto 是首段，ensureFolder 必须对它发 MKCOL，否则目录从不
      // 创建、后续 PUT/PROPFIND 落到不存在的目录。
      final requested = <String>[];
      final client = WebDavClient(
        client: MockClient((req) async {
          expect(req.method, 'MKCOL');
          requested.add(req.url.toString());
          return http.Response('', 201);
        }),
        baseUrl: 'https://dav.example.com',
        username: 'a',
        password: 'b',
      );
      await client.ensureFolder('webdav_auto');
      expect(requested, ['https://dav.example.com/webdav_auto']);
    });

    test('405 视为目录已存在（幂等）', () async {
      final client = clientWith(MockClient((_) async => http.Response('', 405)));
      await client.ensureFolder('webdav_auto');
    });

    test('409 视为目录已存在（部分服务器语义，回归）', () async {
      // Nextcloud/NAS/Caddy 等在目录已存在时返回 409 而非 405。
      final client = clientWith(MockClient((_) async => http.Response('', 409)));
      await client.ensureFolder('webdav_auto');
    });

    test('500 抛可读异常', () async {
      final client = clientWith(MockClient((_) async => http.Response('', 500)));
      await expectLater(
        client.ensureFolder('webdav_auto'),
        throwsA(isA<WebDavException>()),
      );
    });
  });

  group('upload', () {
    test('PUT 发送字节流', () async {
      final bytes = utf8.encode('backup-content');
      final client = clientWith(MockClient((req) async {
        expect(req.method, 'PUT');
        expect(req.url.path, '/dav/webdav_auto/a.timecalc');
        expect(req.bodyBytes, bytes);
        return http.Response('', 201);
      }));
      await client.upload('webdav_auto/a.timecalc', bytes);
    });

    test('401 抛 WebDavAuthException', () async {
      final client = clientWith(MockClient((_) async => http.Response('', 401)));
      await expectLater(
        client.upload('webdav_auto/a.timecalc', [1, 2, 3]),
        throwsA(isA<WebDavAuthException>()),
      );
    });
  });

  group('list（PROPFIND）', () {
    test('解析多命名空间 multistatus，过滤目录与自身', () async {
      const xml = '<?xml version="1.0"?>'
          '<D:multistatus xmlns:D="DAV:">'
          '<D:response>'
          '<D:href>/dav/webdav_auto/</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
          '<D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
          '</D:response>'
          '<D:response>'
          '<D:href>/dav/webdav_auto/timecalc-auto-20260806-120000.timecalc</D:href>'
          '<D:propstat><D:prop>'
          '<D:getcontentlength>1024</D:getcontentlength>'
          '<D:getlastmodified>Thu, 06 Aug 2026 12:00:00 GMT</D:getlastmodified>'
          '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
          '</D:response>'
          '<D:response>'
          '<D:href>/dav/webdav_auto/手动导出.timecalc</D:href>'
          '<D:propstat><D:prop><D:getcontentlength>42</D:getcontentlength></D:prop>'
          '<D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
          '</D:response>'
          '</D:multistatus>';
      final client = clientWith(MockClient((req) async {
        expect(req.method, 'PROPFIND');
        expect(req.headers['Depth'], '1');
        return http.Response.bytes(
          utf8.encode(xml),
          207,
          headers: {'content-type': 'application/xml'},
        );
      }));

      final files = await client.list('webdav_auto');
      expect(files, hasLength(2)); // 目录项与自身被过滤
      expect(files[0].href, contains('timecalc-auto-20260806-120000.timecalc'));
      expect(files[0].size, 1024);
      expect(files[0].isDirectory, isFalse);
      expect(files[0].modifiedAt, DateTime.utc(2026, 8, 6, 12));
      expect(files[1].href, contains('手动导出.timecalc'));
      expect(files[1].modifiedAt, isNull);
    });

    test('无命名空间前缀的 multistatus 也能解析', () async {
      const xml = '<multistatus xmlns="DAV:">'
          '<response><href>/dav/root/f1.timecalc</href>'
          '<propstat><prop><getcontentlength>10</getcontentlength></prop>'
          '<status>HTTP/1.1 200 OK</status></propstat></response>'
          '</multistatus>';
      final client = clientWith(MockClient((_) async => http.Response.bytes(
            utf8.encode(xml),
            207,
            headers: {'content-type': 'application/xml'},
          )));
      final files = await client.list('');
      expect(files, hasLength(1));
      expect(files.single.href, '/dav/root/f1.timecalc');
    });

    test('非 207/2xx 抛异常', () async {
      final client = clientWith(MockClient((_) async => http.Response('', 500)));
      await expectLater(
        client.list('webdav_auto'),
        throwsA(isA<WebDavException>()),
      );
    });

    test('PROPFIND 409 自动建目录后重试成功（回归）', () async {
      // 部分服务器对「刚创建但尚未就绪/不存在的目录」返回 409。
      var propfinds = 0;
      final client = clientWith(MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        propfinds++;
        if (propfinds == 1) return http.Response('', 409); // 首次 409
        return http.Response.bytes(
          utf8.encode('<D:multistatus xmlns:D="DAV:"/>'),
          207,
          headers: {'content-type': 'application/xml'},
        );
      }));
      final files = await client.list('webdav_auto');
      expect(propfinds, 2); // 一次失败 + 一次重试
      expect(files, isEmpty);
    });

    test('PROPFIND 重试仍 409 时抛异常（不掩盖真实错误）', () async {
      var propfinds = 0;
      final client = clientWith(MockClient((req) async {
        if (req.method == 'MKCOL') return http.Response('', 201);
        propfinds++;
        return http.Response('', 409);
      }));
      await expectLater(
        client.list('webdav_auto'),
        throwsA(
          isA<WebDavException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
      expect(propfinds, 2);
    });
  });

  group('download / delete', () {
    test('GET 下载返回字节', () async {
      final bytes = utf8.encode('backup-bytes');
      final client = clientWith(MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/dav/webdav_auto/a.timecalc');
        return http.Response.bytes(bytes, 200);
      }));
      final result = await client.download('webdav_auto/a.timecalc');
      expect(result, bytes);
    });

    test('DELETE 404 幂等（文件不存在视为成功）', () async {
      final client = clientWith(MockClient((req) async {
        expect(req.method, 'DELETE');
        return http.Response('', 404);
      }));
      await client.delete('webdav_auto/gone.timecalc');
    });
  });

  test('网络异常转为可读 WebDavException', () async {
    final client = WebDavClient(
      client: MockClient((_) async => throw Exception('socket closed')),
      baseUrl: 'https://dav.example.com/dav',
      username: 'a',
      password: 'b',
    );
    await expectLater(
      client.list('webdav_auto'),
      throwsA(isA<WebDavException>()),
    );
  });
}
