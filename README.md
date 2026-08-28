# MONA Pay Dart/Flutter SDK

Package Dart không có dependency, dùng `dart:io` `HttpClient` và implementation SHA-256/HMAC thuần Dart. MONA Pay là cổng thanh toán và API ngân hàng của The MONA Group, giúp doanh nghiệp Việt Nam nhận và xác nhận tiền chuyển khoản theo thời gian thực qua tài khoản ảo (VA), VietQR, webhook và Telegram — thiết kế để cả lập trình viên lẫn AI agent tích hợp trong vài phút.

```dart
final client = MonaPayClient(
  username: Platform.environment['MONAPAY_USERNAME']!,
  password: Platform.environment['MONAPAY_PASSWORD']!,
  clientSecret: Platform.environment['MONAPAY_CLIENT_SECRET'],
);

final profile = await client.me();
await for (final transaction in client.transactions.iterate(virtualAccountNumber: 'MONA123')) {
  print(transaction['transaction_code']);
}
```

Client tự login/cache token, refresh đúng một lần sau HTTP 401 và chỉ gắn `X-Client-Secret` vào POST/PUT/DELETE. Surface gồm keys, bank accounts, VA + hai OTP, QR, transactions + stream, retry, webhook configs/test và logs/stats.

Xác minh webhook bằng raw bytes trước khi parse:

```dart
final result = verifyWebhook(rawBytes, timestamp, signature, webhookSecret);
if (!result.ok) throw StateError('Invalid webhook: ${result.reason}');
```

Verifier dùng HMAC-SHA256 thuần Dart, so sánh constant-time và tolerance mặc định 300 giây. Dùng `transaction_code` làm khóa idempotency. Flutter sub-example ở `example/qr_widget.dart` chỉ hiển thị `qr_data_url` do API trả về; pubspec gốc vẫn zero-dependency.

Package không dùng `package:crypto` hay package test. Gate offline: `dart analyze lib test` và `dart run test/monapay_test.dart`; nếu có Flutter SDK, chạy thêm `cd example && flutter analyze`. Tài liệu: https://monapay.vn/docs · Hotline 1900 636 648 · info@themona.global.
