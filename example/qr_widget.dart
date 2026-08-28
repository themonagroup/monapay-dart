import 'package:flutter/material.dart';
import 'package:monapay/monapay.dart';

class MonaPayQrWidget extends StatefulWidget {
  const MonaPayQrWidget({required this.client, required this.orderId, required this.amount, super.key});

  final MonaPayClient client;
  final String orderId;
  final int amount;

  @override
  State<MonaPayQrWidget> createState() => _MonaPayQrWidgetState();
}

class _MonaPayQrWidgetState extends State<MonaPayQrWidget> {
  late final Future<dynamic> qr = widget.client.qr.generate({
    'ownerNumber': '0123456789',
    'ownerType': 'PER',
    'merchantId': 'MONA',
    'terminalId': 'FLUTTER',
    'orderId': widget.orderId,
    'virtualAccountPrefix': 'MONA',
    'beneficiaryName': 'MONA STORE',
    'amount': widget.amount,
    'description': widget.orderId,
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<dynamic>(
        future: qr,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('Không tạo được QR: ${snapshot.error}');
          if (!snapshot.hasData) return const CircularProgressIndicator();
          final dataUrl = (snapshot.data as Map)['qr_data_url'] as String;
          // API đã trả ảnh QR dạng data URL; widget không tự dựng/vẽ lại mã QR.
          return Image.network(dataUrl, semanticLabel: 'VietQR ${widget.orderId}');
        },
      );
}
