import 'dart:async';

import 'package:flutter/widgets.dart';

enum AppNoticeKind { info, success, error, remote }

@immutable
class AppNotice {
  const AppNotice({
    required this.title,
    required this.kind,
    required this.identity,
    this.body,
    this.duration = const Duration(seconds: 3),
    this.hasAction = false,
    this.onTap,
    this.icon,
  });

  final String title;
  final String? body;
  final AppNoticeKind kind;
  // Includes remote ID or local diagnostic details, not just visible text.
  final Object identity;
  final Duration duration;
  final bool hasAction;
  final VoidCallback? onTap;
  final IconData? icon;
}

@immutable
class AppNoticeEntry {
  const AppNoticeEntry(this.id, this.notice, {this.count = 1});

  final int id;
  final AppNotice notice;
  final int count;
}

class AppNoticeHandle {
  const AppNoticeHandle._(this._controller, this.id);

  final AppNoticeController _controller;
  final int id;

  void dismiss() => _controller.dismiss(id);
}

enum AppNoticePause { hover, focus, background }

/// Shared by UI alerts and remote delivery fallback. No host means no delivery.
final appNoticeController = AppNoticeController();

class AppNoticeController extends ChangeNotifier {
  static const maxEntries = 3;
  final List<AppNoticeEntry> _entries = [];
  final Set<AppNoticePause> _paused = {};
  Timer? _timer;
  int _nextId = 0;
  bool _attached = false;

  List<AppNoticeEntry> get entries => List.unmodifiable(_entries);

  void attach() {
    assert(!_attached, 'Only one notification host may own a controller.');
    _attached = true;
  }

  void detach() {
    _attached = false;
    _timer?.cancel();
    _timer = null;
    _entries.clear();
    _paused.clear();
  }

  AppNoticeHandle? show(AppNotice notice) {
    if (!_attached) return null;
    final index = _entries.indexWhere((entry) => entry.notice.identity == notice.identity);
    final previous = index < 0 ? null : _entries.removeAt(index);
    final entry = AppNoticeEntry(previous?.id ?? _nextId++, notice, count: (previous?.count ?? 0) + 1);
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) _entries.removeLast();
    _restartTimer();
    notifyListeners();
    return AppNoticeHandle._(this, entry.id);
  }

  void dismiss(int id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    _entries.removeAt(index);
    if (index == 0) _restartTimer();
    notifyListeners();
  }

  void activate(int id) {
    // Only the readable front card can run an action, and only once.
    if (_entries.isEmpty || _entries.first.id != id) return;
    final callback = _entries.first.notice.onTap;
    dismiss(id);
    callback?.call();
  }

  void pause(AppNoticePause reason, {required bool paused}) {
    final changed = paused ? _paused.add(reason) : _paused.remove(reason);
    if (changed) _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_attached || _paused.isNotEmpty || _entries.isEmpty) return;
    final entry = _entries.first;
    // A promoted card, a repeat, or the end of interaction gets a full reading
    // interval. Covered cards never expire before they can be read.
    _timer = Timer(entry.notice.duration, () => dismiss(entry.id));
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
