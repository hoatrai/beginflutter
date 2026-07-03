import 'dart:async';

class GlobalUserStream {
  static final StreamController<int> controller =
  StreamController<int>.broadcast();

  static Stream<int> get stream => controller.stream;

  static void notify(int userId) {
    controller.add(userId);
  }
}