import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a long mailbox operation alive when the user leaves the app.
///
/// Without this, a running sort is an ordinary backgrounded app: Android is
/// free to kill it as soon as it wants memory, and once the screen goes off
/// Doze throttles the network. On a mailbox with tens of thousands of mails a
/// run takes hours, so "may be killed" means "will be killed" — and the user
/// cannot be expected to sit and watch the screen for that long.
///
/// The guard promotes the app to a foreground service, but only once an
/// operation has actually outlived [threshold]. Short work — listing folders,
/// testing the connection — finishes before that and never raises a
/// notification, so the common case stays quiet. That is the whole reason for
/// the delay: a notification that flashes up for every one-second action is
/// noise, and noise gets silenced.
///
/// Nesting is counted, not toggled. A batch run that calls smaller guarded
/// operations inside itself must not have the service pulled out from under it
/// when the first inner one returns.
class LongRunGuard {
  LongRunGuard._();

  static const MethodChannel _channel = MethodChannel('tyrannofi/longrun');

  /// How long an operation may run before it is worth protecting.
  static const Duration threshold = Duration(seconds: 30);

  static int _depth = 0;
  static Timer? _timer;
  static bool _active = false;
  static String _title = 'TyrannoFi';
  static String _text = '';

  /// True while the foreground service is running. For tests and diagnostics.
  @visibleForTesting
  static bool get isActive => _active;

  @visibleForTesting
  static int get depth => _depth;

  /// Run [body] under protection, promoting to a foreground service if it
  /// takes longer than [threshold].
  ///
  /// The service is always stopped afterwards, including when [body] throws —
  /// a crashed sort must not leave a notification claiming work is still going
  /// on.
  static Future<T> run<T>(String title, Future<T> Function() body) async {
    begin(title);
    try {
      return await body();
    } finally {
      await end();
    }
  }

  /// Start protecting. Paired with [end].
  ///
  /// Hooked to the IMAP connection rather than to each operation: every long
  /// job in this app holds one connection for exactly as long as it works, so
  /// login and logout bracket the work more reliably than a list of method
  /// names that someone will forget to extend.
  static void begin([String title = 'Mailbox operation in progress']) =>
      _enter(title);

  /// Stop protecting. Safe to call more often than [begin] — the counter never
  /// goes below zero, so an unpaired logout cannot strand the service.
  static Future<void> end() => _leave();

  /// Update the line under the title, e.g. "142 of 660 folders".
  ///
  /// Safe to call at any rate: it is ignored while no service is running, and
  /// unchanged text is not sent again. A progress callback fires per chunk of
  /// mail, which would otherwise mean thousands of channel calls.
  static void progress(String text) {
    if (text == _text) return;
    _text = text;
    if (_active) _invoke('update');
  }

  static void _enter(String title) {
    _depth++;
    if (_depth > 1) return; // Inner call: the outer one holds the service.
    _title = title;
    _text = '';
    _timer?.cancel();
    _timer = Timer(threshold, () {
      if (_depth > 0) {
        _active = true;
        _invoke('start');
      }
    });
  }

  static Future<void> _leave() async {
    if (_depth > 0) _depth--;
    if (_depth > 0) return;
    _timer?.cancel();
    _timer = null;
    if (_active) {
      _active = false;
      await _invoke('stop');
    }
  }

  /// Channel failures are swallowed on purpose. The guard is a comfort, not a
  /// prerequisite: on a platform without the service — a test, a desktop build
  /// — the operation itself must still run to completion.
  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod(method, {'title': _title, 'text': _text});
    } catch (e) {
      debugPrint('[TyrannoFi] LongRunGuard.$method: $e');
    }
  }

  /// Drop all state. Only for tests — production has no reason to forget that
  /// a run is in progress.
  @visibleForTesting
  static void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _depth = 0;
    _active = false;
    _title = 'TyrannoFi';
    _text = '';
  }
}
