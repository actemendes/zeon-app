import 'dart:async';
import 'dart:typed_data';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/home_tips/home_tip.dart';

/// Optional content never delays or fails subscription refresh. No polling timer.
class HomeTipController extends StateNotifier<HomeTipContent?> {
  HomeTipController({
    required this.preferences,
    required this.currentUser,
    required this.fetchTip,
    required this.fetchImage,
  }) : super(null);

  final SharedPreferences preferences;
  final String Function() currentUser;
  final Future<HomeTip?> Function() fetchTip;
  final Future<Uint8List> Function(HomeTip) fetchImage;
  int _generation = 0;
  String? _owner;
  Timer? _expiry;
  final Set<String> _sessionDismissed = {};

  String _key(String owner) => 'home_tips_dismissed_v1_$owner';
  bool _dismissed(String owner, HomeTip tip) =>
      _sessionDismissed.contains('$owner:${tip.dismissalKey}') ||
      (preferences.getStringList(_key(owner)) ?? []).contains(tip.dismissalKey);

  Future<void> refresh() async {
    final generation = ++_generation;
    final owner = currentUser();
    _expiry?.cancel();
    state = null;
    _owner = owner;
    if (owner.isEmpty) return;
    bool current() => mounted && generation == _generation && owner == currentUser();
    try {
      final tip = await fetchTip();
      if (!current() || tip == null || tip.expired || _dismissed(owner, tip)) return;
      final bytes = await fetchImage(tip);
      if (!current() || tip.expired || _dismissed(owner, tip)) return;
      state = HomeTipContent(tip, bytes);
      final expires = tip.expiresAt;
      if (expires != null) {
        _expiry = Timer(expires.difference(DateTime.now().toUtc()), () {
          if (current()) state = null;
        });
      }
    } catch (_) {
      // Tips are optional; errors never escape into the profile/VPN pipeline.
      if (current()) state = null;
    }
  }

  Future<void> dismiss() async {
    final content = state;
    final owner = _owner;
    if (content == null || owner == null || owner != currentUser()) return;
    ++_generation;
    _expiry?.cancel();
    state = null;
    _sessionDismissed.add('$owner:${content.tip.dismissalKey}');
    final dismissed = preferences.getStringList(_key(owner)) ?? [];
    dismissed.remove(content.tip.dismissalKey);
    dismissed.add(content.tip.dismissalKey);
    // Keep a bounded history so switching campaigns does not resurrect a closed tip.
    try {
      await preferences.setStringList(
        _key(owner),
        dismissed.length > 100 ? dismissed.sublist(dismissed.length - 100) : dismissed,
      );
    } catch (_) {
      // Remain hidden for this session even if storage is unavailable.
    }
  }

  @override
  void dispose() {
    ++_generation;
    _expiry?.cancel();
    super.dispose();
  }
}
