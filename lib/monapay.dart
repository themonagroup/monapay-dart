library monapay;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const String monaPayVersion = '0.4.0';
const String monaPayDefaultBaseUrl = 'https://api.monapay.vn';

class MonaPayException implements Exception {
  MonaPayException(this.message, {this.status, this.body});

  final String message;
  final int? status;
  final Object? body;

  @override
  String toString() =>
      'MonaPayException${status == null ? '' : ' ($status)'}: $message';
}

class MonaPayHttpRequest {
  const MonaPayHttpRequest({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
}

class MonaPayHttpResponse {
  const MonaPayHttpResponse(this.status, this.body);

  final int status;
  final String body;
}

typedef MonaPayTransport = Future<MonaPayHttpResponse> Function(
  MonaPayHttpRequest request,
);

class MonaPayClient {
  MonaPayClient({
    String? clientId,
    String? username,
    String? password,
    String? clientSecret,
    String baseUrl = monaPayDefaultBaseUrl,
    MonaPayTransport? transport,
    HttpClient? httpClient,
  }) : _clientId = clientId ?? '',
       _username = username ?? '',
       _password = password ?? '',
       _clientSecret = clientSecret ?? '',
       baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _httpClient = httpClient ?? HttpClient() {
    final hasClientCredentials =
        _clientId.trim().isNotEmpty && _clientSecret.trim().isNotEmpty;
    final hasPasswordCredentials =
        _username.trim().isNotEmpty && _password.isNotEmpty;
    if (!hasClientCredentials && !hasPasswordCredentials) {
      throw ArgumentError(
        'Cần clientId + clientSecret hoặc username + password; không dùng password cho AI agent vì sẽ gãy khi bật 2FA',
      );
    }
    final parsed = Uri.tryParse(this.baseUrl);
    if (parsed == null ||
        !parsed.hasScheme ||
        !parsed.hasAuthority ||
        !const ['http', 'https'].contains(parsed.scheme)) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'phải là URL http/https hợp lệ',
      );
    }
    _transport = transport ?? _sendHttp;
    keys = KeysResource(this);
    va = VirtualAccountsResource(this);
    bankAccounts = BankAccountsResource(this);
    paymentProfile = PaymentProfileResource(this);
    checkouts = CheckoutsResource(this);
    qr = QrResource(this);
    transactions = TransactionsResource(this);
    webhooks = WebhooksResource(this);
    webhookLogs = WebhookLogsResource(this);
    sandbox = SandboxResource(this);
    emailConfigs = EmailConfigsResource(this);
    emailLogs = EmailLogsResource(this);
    emailSuppressions = EmailSuppressionsResource(this);
  }

  factory MonaPayClient.fromEnv({
    Map<String, String>? environment,
    MonaPayTransport? transport,
    HttpClient? httpClient,
  }) {
    final values = environment ?? Platform.environment;
    return MonaPayClient(
      clientId: values['MONAPAY_CLIENT_ID'],
      clientSecret: values['MONAPAY_CLIENT_SECRET'],
      username: values['MONAPAY_USERNAME'],
      password: values['MONAPAY_PASSWORD'],
      baseUrl: values['MONAPAY_BASE_URL'] ?? monaPayDefaultBaseUrl,
      transport: transport,
      httpClient: httpClient,
    );
  }

  final String _clientId;
  final String _username;
  final String _password;
  final HttpClient _httpClient;
  final String baseUrl;
  late final MonaPayTransport _transport;
  String _clientSecret;
  String? _accessToken;
  DateTime _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );
  Future<String>? _loginInFlight;

  late final KeysResource keys;
  late final VirtualAccountsResource va;
  late final BankAccountsResource bankAccounts;
  late final PaymentProfileResource paymentProfile;
  late final CheckoutsResource checkouts;
  late final QrResource qr;
  late final TransactionsResource transactions;
  late final WebhooksResource webhooks;
  late final WebhookLogsResource webhookLogs;
  late final SandboxResource sandbox;
  late final EmailConfigsResource emailConfigs;
  late final EmailLogsResource emailLogs;
  late final EmailSuppressionsResource emailSuppressions;

  Future<String> login() async {
    final cached = _accessToken;
    if (cached != null &&
        cached.isNotEmpty &&
        DateTime.now().toUtc().isBefore(_tokenExpiresAt))
      return cached;
    final active = _loginInFlight;
    if (active != null) return active;

    final future = _performLogin();
    _loginInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_loginInFlight, future)) _loginInFlight = null;
    }
  }

  Future<String> _performLogin() async {
    final usingClientCredentials =
        _clientId.isNotEmpty && _clientSecret.isNotEmpty;
    final data = await _send(
      'POST',
      usingClientCredentials ? '/api/v1/oauth/token' : '/api/v1/client/login',
      body: usingClientCredentials
          ? {
              'grant_type': 'client_credentials',
              'client_id': _clientId,
              'client_secret': _clientSecret,
            }
          : {'username': _username, 'password': _password},
      authenticated: false,
    );
    final token = data is Map ? data['access_token']?.toString() : null;
    if (token == null || token.isEmpty) {
      throw MonaPayException(
        'Response đăng nhập không có access_token',
        body: data,
      );
    }
    _accessToken = token;
    final rawExpires = data is Map ? data['expires_in'] : null;
    final expiresIn = rawExpires is num
        ? rawExpires.toDouble()
        : (usingClientCredentials ? 3600.0 : 86400.0);
    _tokenExpiresAt = DateTime.now().toUtc().add(
      Duration(
        milliseconds: ((expiresIn - 60).clamp(0, double.infinity) * 1000)
            .round(),
      ),
    );
    return token;
  }

  Future<dynamic> me() => request('GET', '/api/v1/client/me');

  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    Map<String, String?>? query,
    Map<String, String>? headers,
  }) async {
    final token = await login();
    try {
      return await _send(
        method,
        path,
        body: body,
        query: query,
        token: token,
        customHeaders: headers,
      );
    } on MonaPayException catch (error) {
      if (error.status != 401) rethrow;
      if (_accessToken == token) {
        _accessToken = null;
        _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
      final refreshed = await login();
      return _send(
        method,
        path,
        body: body,
        query: query,
        token: refreshed,
        customHeaders: headers,
      );
    }
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String?>? query,
    String? token,
    bool authenticated = true,
    Map<String, String>? customHeaders,
  }) async {
    final cleanQuery = <String, String>{};
    query?.forEach((key, value) {
      if (value != null && value.isNotEmpty) cleanQuery[key] = value;
    });
    var uri = Uri.parse('$baseUrl$path');
    if (cleanQuery.isNotEmpty) uri = uri.replace(queryParameters: cleanQuery);

    final encoded = body == null ? null : jsonEncode(body);
    final headers = <String, String>{'Accept': 'application/json'};
    if (encoded != null) headers['Content-Type'] = 'application/json';
    if (authenticated && token != null && token.isNotEmpty)
      headers['Authorization'] = 'Bearer $token';
    if (authenticated && method != 'GET' && _clientSecret.isNotEmpty) {
      headers['X-Client-Secret'] = _clientSecret;
    }
    if (customHeaders != null) headers.addAll(customHeaders);

    MonaPayHttpResponse response;
    try {
      response = await _transport(
        MonaPayHttpRequest(
          method: method,
          url: uri,
          headers: headers,
          body: encoded,
        ),
      );
    } catch (error) {
      if (error is MonaPayException) rethrow;
      throw MonaPayException(
        'Không kết nối được MONA Pay: $error',
        body: error,
      );
    }

    dynamic envelope;
    try {
      envelope = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on FormatException {
      throw MonaPayException(
        'MONA Pay trả response không phải JSON (HTTP ${response.status})',
        status: response.status,
        body: response.body,
      );
    }
    final failedEnvelope = envelope is Map && envelope['success'] == false;
    if (response.status < 200 || response.status >= 300 || failedEnvelope) {
      final message = envelope is Map
          ? (envelope['message'] ?? envelope['detail'])?.toString()
          : null;
      throw MonaPayException(
        message == null || message.isEmpty
            ? 'MONA Pay API lỗi HTTP ${response.status}'
            : message,
        status: response.status,
        body: envelope,
      );
    }
    return envelope is Map ? envelope['data'] : null;
  }

  Future<MonaPayHttpResponse> _sendHttp(MonaPayHttpRequest request) async {
    final outgoing = await _httpClient.openUrl(request.method, request.url);
    request.headers.forEach((name, value) => outgoing.headers.set(name, value));
    if (request.body != null) outgoing.add(utf8.encode(request.body!));
    final incoming = await outgoing.close();
    final raw = await utf8.decoder.bind(incoming).join();
    return MonaPayHttpResponse(incoming.statusCode, raw);
  }

  void useClientSecret(String secret) {
    _clientSecret = secret;
  }

  void close() {
    _httpClient.close(force: false);
  }
}

abstract class _Resource {
  const _Resource(this.client);

  final MonaPayClient client;

  String segment(Object value) => Uri.encodeComponent(value.toString());
}

class KeysResource extends _Resource {
  const KeysResource(super.client);

  Future<dynamic> generate([String name = 'Default Key']) async {
    final data = await client.request(
      'POST',
      '/api/v1/client-keys/generate',
      body: {'name': name},
    );
    if (data is Map &&
        data['client_secret'] != null &&
        data['client_secret'].toString().isNotEmpty) {
      client.useClientSecret(data['client_secret'].toString());
    }
    return data;
  }

  Future<dynamic> list() => client.request('GET', '/api/v1/client-keys/list');

  Future<dynamic> destroy(String keyId) =>
      client.request('DELETE', '/api/v1/client-keys/destroy/${segment(keyId)}');

  Future<dynamic> reveal(
    String keyId,
    Map<String, dynamic> confirmation,
  ) => client.request(
    'POST',
    '/api/v1/client-keys/${segment(keyId)}/reveal',
    body: confirmation,
  );

  Future<dynamic> rotate(String keyId) async {
    final data = await client.request(
      'POST',
      '/api/v1/client-keys/${segment(keyId)}/rotate',
      body: const <String, dynamic>{},
    );
    if (data is Map && data['client_secret'] != null) {
      client.useClientSecret(data['client_secret'].toString());
    }
    return data;
  }
}

class VirtualAccountsResource extends _Resource {
  const VirtualAccountsResource(super.client);

  Future<dynamic> register(Map<String, dynamic> body) => client.request(
    'POST',
    '/api/v1/acb/virtual-account/registration',
    body: body,
  );

  Future<dynamic> verify(String requestId, String code) => client.request(
    'POST',
    '/api/v1/acb/${segment(requestId)}/virtual-account/verification',
    body: {'code': code},
  );

  Future<dynamic> registerNotification(
    String virtualAccountId, [
    Map<String, dynamic> body = const {},
  ]) => client.request(
    'POST',
    '/api/v1/acb/${segment(virtualAccountId)}/notification/registration',
    body: body,
  );

  Future<dynamic> verifyNotification(String requestId, String code) =>
      client.request(
        'POST',
        '/api/v1/acb/${segment(requestId)}/notification/verification',
        body: {'code': code},
      );

  Future<dynamic> list(String bankAccountId) => client.request(
    'GET',
    '/api/v1/acb/${segment(bankAccountId)}/virtual-account/retrieve',
  );
}

class BankAccountsResource extends _Resource {
  const BankAccountsResource(super.client);

  Future<dynamic> list() =>
      client.request('GET', '/api/v1/client/bank-accounts');
}

class PaymentProfileResource extends _Resource {
  const PaymentProfileResource(super.client);

  Future<dynamic> get() => client.request('GET', '/api/v1/payment-profile');

  Future<dynamic> set(Map<String, dynamic> body) =>
      client.request('PUT', '/api/v1/payment-profile', body: body);

  Future<dynamic> rotateReturnSecret() => client.request(
    'POST',
    '/api/v1/payment-profile/rotate-return-secret',
    body: const <String, dynamic>{},
  );

  Future<dynamic> revealReturnSecret(Map<String, dynamic> confirmation) =>
      client.request(
        'POST',
        '/api/v1/payment-profile/reveal-return-secret',
        body: confirmation,
      );
}

class CheckoutsResource extends _Resource {
  const CheckoutsResource(super.client);

  Future<dynamic> create(
    Map<String, dynamic> body, {
    String? idempotencyKey,
  }) => client.request(
    'POST',
    '/api/v1/checkouts',
    body: body,
    headers: {'Idempotency-Key': _idempotencyKey(idempotencyKey)},
  );

  Future<dynamic> get(String checkoutId) =>
      client.request('GET', '/api/v1/checkouts/${segment(checkoutId)}');

  Future<dynamic> list({
    String? status,
    String? orderCode,
    String? fromDate,
    String? toDate,
    int? page,
    int? limit,
  }) => client.request(
    'GET',
    '/api/v1/checkouts',
    query: {
      'status': status,
      'order_code': orderCode,
      'from_date': fromDate,
      'to_date': toDate,
      'page': page?.toString(),
      'limit': limit?.toString(),
    },
  );

  Future<dynamic> cancel(
    String checkoutId, {
    String? idempotencyKey,
  }) => client.request(
    'POST',
    '/api/v1/checkouts/${segment(checkoutId)}/cancel',
    body: const <String, dynamic>{},
    headers: {'Idempotency-Key': _idempotencyKey(idempotencyKey)},
  );
}

String _idempotencyKey(String? supplied) {
  if (supplied != null && supplied.isNotEmpty) return supplied;
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class QrResource extends _Resource {
  const QrResource(super.client);

  Future<dynamic> generate(Map<String, dynamic> body) =>
      client.request('POST', '/api/v1/acb/qr-payment/generate', body: body);

  Future<dynamic> cancel(String qrCodeId, [Map<String, dynamic>? body]) =>
      client.request(
        'DELETE',
        '/api/v1/acb/qr-payment/${segment(qrCodeId)}/cancellation',
        body: body,
      );
}

class TransactionsResource extends _Resource {
  const TransactionsResource(super.client);

  Future<dynamic> list({
    required String virtualAccountNumber,
    int page = 1,
    int limit = 100,
  }) {
    if (virtualAccountNumber.isEmpty)
      throw ArgumentError('virtualAccountNumber là bắt buộc');
    return client.request(
      'GET',
      '/api/v1/acb/virtual-account/transactions',
      query: {
        'virtual_account_number': virtualAccountNumber,
        'page': (page > 0 ? page : 1).toString(),
        'limit': (limit > 0 ? limit : 100).toString(),
      },
    );
  }

  Stream<dynamic> iterate({
    required String virtualAccountNumber,
    int page = 1,
    int limit = 100,
    String? sinceId,
  }) async* {
    var currentPage = page > 0 ? page : 1;
    final pageSize = limit > 0 ? limit : 100;
    var stopped = false;
    while (!stopped) {
      final response = await list(
        virtualAccountNumber: virtualAccountNumber,
        page: currentPage,
        limit: pageSize,
      );
      if (response is! Map)
        throw MonaPayException(
          'Response giao dịch không phải object',
          body: response,
        );
      final items = response['data'];
      if (items is List) {
        for (final item in items) {
          if (sinceId != null &&
              item is Map &&
              (item['id']?.toString() == sinceId ||
                  item['transaction_code']?.toString() == sinceId)) {
            stopped = true;
            break;
          }
          yield item;
        }
      }
      if (stopped) break;
      final hasNext = response.containsKey('has_next')
          ? response['has_next'] == true
          : currentPage < _toInt(response['last_page'], currentPage);
      if (!hasNext) break;
      currentPage += 1;
    }
  }

  Future<dynamic> retry(
    String transactionId, {
    required String targetType,
    String? targetId,
  }) {
    final body = <String, dynamic>{'target_type': targetType};
    if (targetId != null && targetId.isNotEmpty) body['target_id'] = targetId;
    return client.request(
      'POST',
      '/api/v1/acb/virtual-account/transactions/${segment(transactionId)}/retry',
      body: body,
    );
  }

  static int _toInt(dynamic value, int fallback) =>
      int.tryParse(value?.toString() ?? '') ?? fallback;
}

class WebhooksResource extends _Resource {
  const WebhooksResource(super.client);

  Future<dynamic> list() => client.request('GET', '/api/v1/client-webhooks');

  Future<dynamic> create(Map<String, dynamic> body) =>
      client.request('POST', '/api/v1/client-webhooks', body: body);

  Future<dynamic> update(String configId, Map<String, dynamic> body) =>
      client.request(
        'PUT',
        '/api/v1/client-webhooks/${segment(configId)}',
        body: body,
      );

  Future<dynamic> remove(String configId) =>
      client.request('DELETE', '/api/v1/client-webhooks/${segment(configId)}');

  Future<dynamic> test([
    Map<String, dynamic> body = const {'is_dummy': true},
  ]) => client.request('POST', '/api/v1/client-webhooks/test', body: body);
}

class WebhookLogsResource extends _Resource {
  const WebhookLogsResource(super.client);

  Future<dynamic> list({
    String? status,
    String? fromDate,
    String? toDate,
    int? page,
    int? limit,
  }) => client.request(
    'GET',
    '/api/v1/webhook-logs',
    query: _query(status, fromDate, toDate, page, limit),
  );

  Future<dynamic> stats({
    String? status,
    String? fromDate,
    String? toDate,
    int? page,
    int? limit,
  }) => client.request(
    'GET',
    '/api/v1/webhook-logs/stats',
    query: _query(status, fromDate, toDate, page, limit),
  );

  static Map<String, String?> _query(
    String? status,
    String? fromDate,
    String? toDate,
    int? page,
    int? limit,
  ) => {
    'status': status,
    'from_date': fromDate,
    'to_date': toDate,
    'page': page?.toString(),
    'limit': limit?.toString(),
  };
}

class SandboxResource extends _Resource {
  const SandboxResource(super.client);

  Future<dynamic> createTransaction(Map<String, dynamic> body) =>
      client.request('POST', '/api/v1/sandbox/transactions', body: body);
}

class EmailConfigsResource extends _Resource {
  const EmailConfigsResource(super.client);

  Future<dynamic> list() => client.request('GET', '/api/v1/email-configs');
  Future<dynamic> create(Map<String, dynamic> body) =>
      client.request('POST', '/api/v1/email-configs', body: body);
  Future<dynamic> get(String configId) =>
      client.request('GET', '/api/v1/email-configs/${segment(configId)}');
  Future<dynamic> update(String configId, Map<String, dynamic> body) => client
      .request('PUT', '/api/v1/email-configs/${segment(configId)}', body: body);
  Future<dynamic> remove(String configId) =>
      client.request('DELETE', '/api/v1/email-configs/${segment(configId)}');
  Future<dynamic> verify(
    String configId, {
    required String email,
    required String code,
  }) => client.request(
    'POST',
    '/api/v1/email-configs/${segment(configId)}/verify',
    body: {'email': email, 'code': code},
  );
  Future<dynamic> resendVerification(String configId, String email) =>
      client.request(
        'POST',
        '/api/v1/email-configs/${segment(configId)}/resend-verification',
        body: {'email': email},
      );
  Future<dynamic> test(String configId) => client.request(
    'POST',
    '/api/v1/email-configs/${segment(configId)}/test',
    body: const <String, dynamic>{},
  );
}

class EmailLogsResource extends _Resource {
  const EmailLogsResource(super.client);

  Future<dynamic> list({
    String? configId,
    String? status,
    String? eventType,
    String? fromDate,
    String? toDate,
    int? page,
    int? limit,
  }) => client.request(
    'GET',
    '/api/v1/email-logs',
    query: _query(configId, status, eventType, fromDate, toDate, page, limit),
  );
  Future<dynamic> stats({String? fromDate, String? toDate}) => client.request(
    'GET',
    '/api/v1/email-logs/stats',
    query: _query(null, null, null, fromDate, toDate, null, null),
  );
  static Map<String, String?> _query(
    String? configId,
    String? status,
    String? eventType,
    String? fromDate,
    String? toDate,
    int? page,
    int? limit,
  ) => {
    'config_id': configId,
    'status': status,
    'event_type': eventType,
    'from_date': fromDate,
    'to_date': toDate,
    'page': page?.toString(),
    'limit': limit?.toString(),
  };
}

class EmailSuppressionsResource extends _Resource {
  const EmailSuppressionsResource(super.client);

  Future<dynamic> list() => client.request('GET', '/api/v1/email-suppressions');
  Future<dynamic> remove(String email) =>
      client.request('DELETE', '/api/v1/email-suppressions/${segment(email)}');
}

class WebhookResult {
  const WebhookResult._(this.ok, this.reason, this.payload);

  const WebhookResult.valid(dynamic payload) : this._(true, null, payload);
  const WebhookResult.invalid(String reason) : this._(false, reason, null);

  final bool ok;
  final String? reason;
  final dynamic payload;
}

WebhookResult verifyWebhook(
  List<int> raw,
  String timestamp,
  String signature,
  String secret, {
  int tolerance = 300,
}) {
  if (tolerance < 0)
    throw ArgumentError.value(tolerance, 'tolerance', 'phải là số không âm');
  if (timestamp.isEmpty)
    return const WebhookResult.invalid('missing_timestamp');
  if (!RegExp(r'^\d+$').hasMatch(timestamp))
    return const WebhookResult.invalid('invalid_timestamp');
  final unix = int.tryParse(timestamp);
  if (unix == null) return const WebhookResult.invalid('invalid_timestamp');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if ((now - unix).abs() > tolerance)
    return const WebhookResult.invalid('timestamp_out_of_tolerance');
  if (signature.isEmpty)
    return const WebhookResult.invalid('missing_signature');

  final expected = _hmacSha256(utf8.encode(secret), <int>[
    ...utf8.encode('$timestamp.'),
    ...raw,
  ]);
  final validFormat = RegExp(r'^sha256=[0-9a-fA-F]{64}$').hasMatch(signature);
  final supplied = validFormat
      ? _decodeHex(signature.substring(7))
      : Uint8List(32);
  if (!_constantTimeEquals(expected, supplied) || !validFormat) {
    return const WebhookResult.invalid('invalid_signature');
  }
  try {
    return WebhookResult.valid(
      jsonDecode(utf8.decode(raw, allowMalformed: false)),
    );
  } on FormatException {
    return const WebhookResult.invalid('invalid_json');
  }
}

Uint8List _hmacSha256(List<int> key, List<int> message) {
  var normalized = Uint8List.fromList(key);
  if (normalized.length > 64) normalized = _sha256(normalized);
  final padded = Uint8List(64)..setRange(0, normalized.length, normalized);
  final innerPad = Uint8List.fromList(
    padded.map((byte) => byte ^ 0x36).toList(),
  );
  final outerPad = Uint8List.fromList(
    padded.map((byte) => byte ^ 0x5c).toList(),
  );
  final inner = _sha256(Uint8List.fromList(<int>[...innerPad, ...message]));
  return _sha256(Uint8List.fromList(<int>[...outerPad, ...inner]));
}

Uint8List _sha256(List<int> input) {
  const constants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  final bytes = <int>[...input];
  final bitLength = bytes.length * 8;
  bytes.add(0x80);
  while (bytes.length % 64 != 56) bytes.add(0);
  for (var shift = 56; shift >= 0; shift -= 8) {
    bytes.add((bitLength >> shift) & 0xff);
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;
  for (var offset = 0; offset < bytes.length; offset += 64) {
    final words = Uint32List(64);
    for (var i = 0; i < 16; i++) {
      final at = offset + i * 4;
      words[i] =
          (bytes[at] << 24) |
          (bytes[at + 1] << 16) |
          (bytes[at + 2] << 8) |
          bytes[at + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 =
          _rotateRight(words[i - 15], 7) ^
          _rotateRight(words[i - 15], 18) ^
          (words[i - 15] >> 3);
      final s1 =
          _rotateRight(words[i - 2], 17) ^
          _rotateRight(words[i - 2], 19) ^
          (words[i - 2] >> 10);
      words[i] = (words[i - 16] + s0 + words[i - 7] + s1) & 0xffffffff;
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;
    for (var i = 0; i < 64; i++) {
      final sum1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choice = (e & f) ^ ((~e) & g);
      final temp1 = (h + sum1 + choice + constants[i] + words[i]) & 0xffffffff;
      final sum0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sum0 + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }
  final output = ByteData(32);
  for (final entry in <MapEntry<int, int>>[
    MapEntry(0, h0),
    MapEntry(1, h1),
    MapEntry(2, h2),
    MapEntry(3, h3),
    MapEntry(4, h4),
    MapEntry(5, h5),
    MapEntry(6, h6),
    MapEntry(7, h7),
  ]) {
    output.setUint32(entry.key * 4, entry.value, Endian.big);
  }
  return output.buffer.asUint8List();
}

int _rotateRight(int value, int amount) =>
    ((value >> amount) | ((value << (32 - amount)) & 0xffffffff)) & 0xffffffff;

Uint8List _decodeHex(String value) {
  final output = Uint8List(value.length ~/ 2);
  for (var i = 0; i < output.length; i++) {
    output[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return output;
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var different = 0;
  for (var i = 0; i < left.length; i++) {
    different |= left[i] ^ right[i];
  }
  return different == 0;
}
