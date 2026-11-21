class UserModel {
  final int id;
  final String username;
  final String fullName;
  final String token;

  const UserModel({
    required this.id,
    required this.username,
    required this.fullName,
    required this.token,
  });

  factory UserModel.fromLoginResponse(Map<String, dynamic> json) {
    // The mobile API nests the account under `user`, while older API
    // responses returned the account fields at the top level. Accept both
    // shapes so the menu profile is populated consistently.
    final nestedUser = json['user'];
    final user = nestedUser is Map
        ? Map<String, dynamic>.from(nestedUser)
        : json;
    return UserModel(
      id: _readInt(user, const ['id', 'user_id']),
      username: _readString(user, const ['username', 'uname']),
      fullName: _readString(user, const ['full_name', 'fullName', 'name']),
      token: (json['token'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'fullName': fullName,
      'token': token,
    };
  }

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: _readInt(json, const ['id', 'user_id']),
      username: _readString(json, const ['username', 'uname']),
      fullName: _readString(json, const ['fullName', 'full_name', 'name']),
      token: (json['token'] ?? '').toString(),
    );
  }

  static String _readString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return '';
  }

  static int _readInt(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return 0;
  }
}
