import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/user_profile_response.dart';

void main() {
  test('current profiles consume generated fields and retain unknown server fields', () {
    final errors = <Object>[];
    final result = decodeUserProfileResponse(
      '{"uid":"user-1","name":"Example","created_at":"2026-10-01T12:00:00+02:00","future_field":true}',
      onSchemaMismatch: errors.add,
    );
    expect(result, {
      'uid': 'user-1',
      'name': 'Example',
      'created_at': '2026-10-01T10:00:00.000Z',
      'future_field': true,
    });
    expect(errors, isEmpty);
  });

  test('hosted profiles without uid still load and report their schema mismatch', () {
    final errors = <Object>[];
    final result = decodeUserProfileResponse(
      '{"data_protection_level":"enhanced","migration_status":{"state":"pending"}}',
      onSchemaMismatch: errors.add,
    );
    expect(result, {
      'data_protection_level': 'enhanced',
      'migration_status': {'state': 'pending'},
    });
    expect(errors, hasLength(1));
  });

  test('a legacy field shape preserves the original profile for compatibility', () {
    final errors = <Object>[];
    expect(
      decodeUserProfileResponse('{"uid":"user-1","name":42}', onSchemaMismatch: errors.add),
      {'uid': 'user-1', 'name': 42},
    );
    expect(errors, hasLength(1));
  });
}
