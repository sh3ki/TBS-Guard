import 'package:flutter_test/flutter_test.dart';

import 'package:tbs_guard/models/user_model.dart';

void main() {
  test('reads profile fields from the mobile login response', () {
    final user = UserModel.fromLoginResponse({
      'token': 'token',
      'user': {
        'id': 7,
        'username': 'guard.user',
        'full_name': 'Guard User',
      },
    });

    expect(user.username, 'guard.user');
    expect(user.fullName, 'Guard User');
  });

  test('restores profile fields from legacy persisted keys', () {
    final user = UserModel.fromJson({
      'id': 7,
      'username': 'guard.user',
      'full_name': 'Guard User',
      'token': 'token',
    });

    expect(user.username, 'guard.user');
    expect(user.fullName, 'Guard User');
  });
}
