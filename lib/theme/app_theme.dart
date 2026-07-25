import 'package:flutter/material.dart';

/// Tone dùng chung cho toàn app — đồng bộ với ProfilePage.
/// Navy (0xFF0D47A1) -> Cam (0xFFF57C00), nền "glass" trắng mờ, chữ trắng.
class AppTheme {
  AppTheme._();

  static const Color primaryBlue = Color(0xFF0D47A1);
  static const Color accentOrange = Color(0xFFF57C00);

  static const Color textWhite = Colors.white;
  static const Color textWhite70 = Colors.white70;
  static const Color textWhite60 = Colors.white60;
  static const Color textWhite38 = Colors.white38;

  static const Color danger = Colors.redAccent;
  static const List<Color> dangerGradient = [Color(0xFFEF4444), Color(0xFFB91C1C)];

  /// Nền "glass" cho card/tile trên nền gradient.
  static Color glassSurface = Colors.white.withOpacity(0.12);
  static Color glassBorder = Colors.white.withOpacity(0.18);

  /// Gradient nền chính — dùng cho Scaffold body (giống ProfilePage).
  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [Color(0xE60D47A1), Color(0xCCF57C00)], // ~90%/80% opacity
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static BoxDecoration get backgroundDecoration =>
      const BoxDecoration(gradient: backgroundGradient);

  /// Bọc 1 Scaffold body sẵn có bằng nền gradient chuẩn của app.
  static Widget wrapBackground(Widget child) {
    return Container(
      decoration: backgroundDecoration,
      child: child,
    );
  }

  static const AppBarTheme appBarTheme = AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    foregroundColor: Colors.white,
    iconTheme: IconThemeData(color: Colors.white),
    titleTextStyle: TextStyle(
      color: Colors.white,
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
  );
}
