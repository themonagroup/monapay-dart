import 'dart:convert';

import 'package:monapay/monapay.dart';

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String envelope(Object? data) => jsonEncode({'success': true, 'message': 'ok', 'data': data});

Future<void> main() async {
  final calls = <MonaPayHttpRequest>[];
  var logins = 0;
  var meCalls = 0;
  final client = MonaPayClient(
    username: 'user',
    password: 'pass',
    clientSecret: 'secret',
    baseUrl: 'https://example.test/',
    transport: (request) async {
      calls.add(request);
      if (request.url.path == '/api/v1/client/login') {
        logins += 1;
        return MonaPayHttpResponse(200, envelope({'access_token': 'token-$logins'}));
      }
      if (request.url.path == '/api/v1/client/me') {
        meCalls += 1;
        if (meCalls == 1) return MonaPayHttpResponse(401, jsonEncode({'detail': 'expired'}));
      }
      return MonaPayHttpResponse(200, envelope({'id': 'ok'}));
    },
  );
  await client.webhooks.create({'name': 'Shop'});
  await client.me();
  expect(logins == 2, 'phải login lại đúng một lần sau 401');
  expect(calls[1].headers['Authorization'] == 'Bearer token-1', 'thiếu bearer token');
  expect(calls[1].headers['X-Client-Secret'] == 'secret', 'thiếu client secret trên POST');
  expect(!calls.last.headers.containsKey('X-Client-Secret'), 'GET không được gửi client secret');
  expect(calls.last.headers['Authorization'] == 'Bearer token-2', 'refresh token không được dùng');
  client.close();

  final pages = <String>[];
  final paging = MonaPayClient(
    username: 'user',
    password: 'pass',
    baseUrl: 'https://example.test',
    transport: (request) async {
      if (request.url.path == '/api/v1/client/login') {
        return MonaPayHttpResponse(200, envelope({'access_token': 'token'}));
      }
      pages.add(request.url.queryParameters['page']!);
      expect(!request.url.queryParameters.containsKey('since_id'), 'since_id không phải query backend');
      final items = request.url.queryParameters['page'] == '1'
          ? [
              {'id': 'tx-3'},
              {'id': 'tx-2'},
            ]
          : [
              {'id': 'tx-1'},
            ];
      return MonaPayHttpResponse(200, envelope({'data': items, 'last_page': 2}));
    },
  );
  final ids = await paging.transactions
      .iterate(virtualAccountNumber: 'MONA 01', limit: 2, sinceId: 'tx-1')
      .map((item) => item['id'] as String)
      .toList();
  expect(jsonEncode(ids) == jsonEncode(['tx-3', 'tx-2']), 'iterator/sinceId sai: $ids');
  expect(jsonEncode(pages) == jsonEncode(['1', '2']), 'phân trang sai: $pages');
  paging.close();

  // Fixed HMAC-SHA256 vector for timestamp 1700000000 and secret "test-secret".
  final webhook = verifyWebhook(
    utf8.encode('{"amount":2500000,"transaction_code":"FT1"}'),
    '1700000000',
    'sha256=6fa02a4bcca12f6a57627e931dc7f3bec85d6fc0f164d64e2353f11c68773fba',
    'test-secret',
    tolerance: 10000000000,
  );
  expect(webhook.ok, 'vector HMAC-SHA256 không khớp: ${webhook.reason}');
  final zeros = List<String>.filled(64, '0').join();
  final bad = verifyWebhook(utf8.encode('{}'), '1700000000', 'sha256=$zeros', 'test-secret', tolerance: 10000000000);
  expect(!bad.ok && bad.reason == 'invalid_signature', 'phải từ chối chữ ký sai');

  print('MONA Pay Dart self-test: PASS');
}
