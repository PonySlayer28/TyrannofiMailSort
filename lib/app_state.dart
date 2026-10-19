import 'package:flutter/foundation.dart';

import 'models/app_config.dart';
import 'models/results.dart';
import 'services/storage_service.dart';

/// Global, in-memory application state. Holds the selected server, its config,
/// the current session password and cached results (scan / dupes) so screens
/// can share data — mirroring the per-server globals in gmail_app.py.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  final _storage = StorageService.instance;

  String _serverKey = 'gmail';
  String get serverKey => _serverKey;

  late AppConfig config;

  /// Session password (kept in memory only; the persistent copy lives in
  /// secure storage).
  String password = '';

  // Cached results per server key.
  final Map<String, ScanResult> _scans = {};
  final Map<String, DupeResult> _dupes = {};

  ScanResult? get scan => _scans[_serverKey];
  DupeResult? get dupes => _dupes[_serverKey];

  void init() {
    _serverKey = _storage.lastServerKey;
    config = _storage.loadConfig(_serverKey);
  }

  Future<void> selectServer(String key) async {
    _serverKey = key;
    await _storage.saveLastServerKey(key);
    config = _storage.loadConfig(key);
    password = await _storage.loadPassword(key, config.email);
    notifyListeners();
  }

  /// Reload config + password for the current server (after edits elsewhere).
  Future<void> reload() async {
    config = _storage.loadConfig(_serverKey);
    if (password.isEmpty) {
      password = await _storage.loadPassword(_serverKey, config.email);
    }
    notifyListeners();
  }

  void setScan(ScanResult r) {
    _scans[_serverKey] = r;
    notifyListeners();
  }

  void setDupes(DupeResult r) {
    _dupes[_serverKey] = r;
    notifyListeners();
  }

  bool get hasCredentials => config.email.isNotEmpty && password.isNotEmpty;
}
