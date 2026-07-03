class UserCache {
  static final Map<int, String> avatarMap = {};
  static final Map<int, String> nameMap = {};

  static void updateUser({
    required int userId,
    String? avatar,
    String? name,
  }) {
    if (avatar != null) {
      avatarMap[userId] = avatar;
    }
    if (name != null) {
      nameMap[userId] = name;
    }
  }

  static String? getAvatar(int userId) {
    return avatarMap[userId];
  }
}