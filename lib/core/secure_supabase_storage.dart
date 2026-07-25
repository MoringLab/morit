import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Stores Supabase sessions and PKCE verifiers in platform secure storage.
///
/// On Android this uses Android Keystore-backed encryption. A session written
/// by the old SharedPreferences default is migrated once and then removed.
final class SecureSupabaseStorage extends LocalStorage
    implements GotrueAsyncStorage {
  SecureSupabaseStorage({
    required String projectUrl,
    FlutterSecureStorage? secureStorage,
  }) : _legacySessionKey =
           'sb-${Uri.parse(projectUrl).host.split('.').first}-auth-token',
       _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(aOptions: AndroidOptions());

  static const _securePrefix = 'moring.supabase.';
  static const _pkceVerifierKey = 'supabase.auth.token-code-verifier';

  final String _legacySessionKey;
  final FlutterSecureStorage _secureStorage;

  String get _secureSessionKey => '$_securePrefix$_legacySessionKey';
  String _securePkceKey(String key) => '${_securePrefix}pkce.$key';

  @override
  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    if (await _secureStorage.read(key: _secureSessionKey) == null) {
      final legacySession = preferences.getString(_legacySessionKey);
      if (legacySession != null && legacySession.isNotEmpty) {
        await _secureStorage.write(
          key: _secureSessionKey,
          value: legacySession,
        );
      }
    }
    await preferences.remove(_legacySessionKey);

    if (await _secureStorage.read(key: _securePkceKey(_pkceVerifierKey)) ==
        null) {
      final legacyVerifier = preferences.getString(_pkceVerifierKey);
      if (legacyVerifier != null && legacyVerifier.isNotEmpty) {
        await _secureStorage.write(
          key: _securePkceKey(_pkceVerifierKey),
          value: legacyVerifier,
        );
      }
    }
    await preferences.remove(_pkceVerifierKey);
  }

  @override
  Future<bool> hasAccessToken() =>
      _secureStorage.containsKey(key: _secureSessionKey);

  @override
  Future<String?> accessToken() => _secureStorage.read(key: _secureSessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _secureStorage.write(key: _secureSessionKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() =>
      _secureStorage.delete(key: _secureSessionKey);

  @override
  Future<String?> getItem({required String key}) =>
      _secureStorage.read(key: _securePkceKey(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      _secureStorage.write(key: _securePkceKey(key), value: value);

  @override
  Future<void> removeItem({required String key}) =>
      _secureStorage.delete(key: _securePkceKey(key));
}
