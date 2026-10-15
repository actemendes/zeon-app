import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/features/mobile/data/external_subscription_sync_service.dart';

class TvSubscriptionPaymentDialog extends ConsumerStatefulWidget {
  const TvSubscriptionPaymentDialog({super.key, required this.uri, required this.refresh});

  final Uri uri;
  final Future<ExternalSubscriptionSyncResult> Function() refresh;

  @override
  ConsumerState<TvSubscriptionPaymentDialog> createState() => _TvSubscriptionPaymentDialogState();
}

class _TvSubscriptionPaymentDialogState extends ConsumerState<TvSubscriptionPaymentDialog> with WidgetsBindingObserver {
  Timer? _timer;
  bool _refreshing = false;
  bool _finished = false;
  bool _updated = false;
  bool _resumed = true;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_refresh()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
  }

  Future<void> _refresh() async {
    if (_refreshing || _finished || !_resumed) return;
    // Bound the fast checks to ten minutes; ordinary profile auto-update remains active.
    if (_attempts++ >= 40) {
      _timer?.cancel();
      return;
    }
    _refreshing = true;
    try {
      final result = await widget.refresh();
      if (!mounted) return;
      if (result == ExternalSubscriptionSyncResult.changed || result == ExternalSubscriptionSyncResult.skipped) {
        _finished = true;
        _timer?.cancel();
        if (result == ExternalSubscriptionSyncResult.changed) setState(() => _updated = true);
      }
    } catch (_) {
      // Temporary network failures keep the QR usable; the next bounded check retries.
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(translationsProvider).requireValue;
    final text = t.pages.profileDetails.specialServers;
    final qr = Center(
      child: QrImageView(
        data: widget.uri.toString(),
        size: 280,
        padding: const EdgeInsets.all(20),
        backgroundColor: Colors.white,
        semanticsLabel: text.tvPaymentTitle,
      ),
    );
    final instructions = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text.tvPaymentScan, style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: 20),
        Text(text.tvPaymentRefresh),
        if (_updated) ...[const SizedBox(height: 20), Semantics(liveRegion: true, child: Text(text.tvPaymentUpdated))],
      ],
    );
    return ZeonDialog(
      maxWidth: 820,
      icon: const Icon(Icons.qr_code_rounded),
      title: Text(text.tvPaymentTitle),
      content: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 650
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  qr,
                  const SizedBox(width: 32),
                  Expanded(child: instructions),
                ],
              )
            : Column(children: [qr, const SizedBox(height: 24), instructions]),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
