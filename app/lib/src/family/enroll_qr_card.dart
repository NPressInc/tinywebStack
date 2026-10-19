import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class EnrollQrCard extends StatelessWidget {
  const EnrollQrCard({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text('Scan with the TinyWeb app on the new phone'),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: QrImageView(
              data: data,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
