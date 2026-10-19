import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'services/spam_service.dart';
import 'services/storage_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageService.instance.init();
  AppState.instance.init();
  // Warm the disposable-domain database in the background.
  SpamService.instance.loadDisposable();
  runApp(const TyrannoFiApp());
}

class TyrannoFiApp extends StatelessWidget {
  const TyrannoFiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TyrannoFi',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
