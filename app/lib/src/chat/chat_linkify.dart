import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the system browser when possible.
Future<void> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return;
  }
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Message body with tappable http(s) links.
class ChatLinkifyText extends StatelessWidget {
  const ChatLinkifyText({
    super.key,
    required this.text,
    required this.style,
    required this.linkColor,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  @override
  Widget build(BuildContext context) {
    return Linkify(
      text: text,
      style: style,
      linkStyle: style.copyWith(
        color: linkColor,
        decoration: TextDecoration.underline,
      ),
      onOpen: (link) => openExternalUrl(link.url),
    );
  }
}
