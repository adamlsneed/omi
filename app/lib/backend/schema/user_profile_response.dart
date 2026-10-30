import 'dart:convert';

import 'package:omi/backend/schema/gen/privacy_wire.g.dart' as wire;

Map<String, dynamic> decodeUserProfileResponse(
  String body, {
  required void Function(Object) onSchemaMismatch,
}) {
  final decoded = jsonDecode(body) as Map<String, dynamic>;
  try {
    final generated = wire.GeneratedUserProfileResponse.fromJson(decoded).toJson();
    return {
      for (final entry in decoded.entries)
        entry.key: generated.containsKey(entry.key) ? generated[entry.key] : entry.value,
    };
  } catch (error) {
    // Older hosted responses can omit required fields, including uid.
    onSchemaMismatch(error);
    return decoded;
  }
}
