import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:morit/core/app_config.dart';

String jwtWithRole(String role) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256'})}.${encode({'role': role})}.signature';
}

void main() {
  test('only public Supabase client key classes are accepted', () {
    expect(AppConfig.isPublicSupabaseKey('sb_publishable_example'), isTrue);
    expect(AppConfig.isPublicSupabaseKey(jwtWithRole('anon')), isTrue);

    expect(AppConfig.isPublicSupabaseKey('sb_secret_example'), isFalse);
    expect(AppConfig.isPublicSupabaseKey(jwtWithRole('service_role')), isFalse);
    expect(AppConfig.isPublicSupabaseKey('not-a-key'), isFalse);
  });
}
