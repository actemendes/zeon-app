import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class TipCard extends StatelessWidget {
  const TipCard({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.5,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        child: Row(
          children: [
            const Padding(padding: EdgeInsets.all(8.0), child: Icon(FluentIcons.lightbulb_24_regular)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Text(message)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
