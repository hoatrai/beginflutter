import 'dart:convert';
import 'package:flutter/material.dart';

typedef AppStateCallback = void Function(String state);

class AppLifecycleTracker extends StatefulWidget {
  final Widget child;
  final AppStateCallback? onStateChanged;

  const AppLifecycleTracker({
    super.key,
    required this.child,
    this.onStateChanged,
  });

  @override
  State<AppLifecycleTracker> createState() => _AppLifecycleTrackerState();
}

class _AppLifecycleTrackerState extends State<AppLifecycleTracker>
    with WidgetsBindingObserver {

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    String appState = "UNKNOWN";

    if (state == AppLifecycleState.resumed) {
      appState = "FOREGROUND";
      debugPrint("🟢 App FOREGROUND");
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      appState = "BACKGROUND";
      debugPrint("🟡 App BACKGROUND");
    }

    if (state == AppLifecycleState.detached) {
      appState = "KILLED";
      debugPrint("⚪ App KILLED");
    }

    widget.onStateChanged?.call(appState);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
