import 'dart:convert';

abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static const authRedirectUriValue = String.fromEnvironment(
    'AUTH_REDIRECT_URI',
    defaultValue: 'morit://auth/callback',
  );
  static const downloadApiUrlValue = String.fromEnvironment('DOWNLOAD_API_URL');

  static Uri get authRedirectUri => Uri.parse(authRedirectUriValue);
  static Uri? get downloadApiUri {
    final value = downloadApiUrlValue.trim();
    return value.isEmpty ? null : Uri.tryParse(value);
  }

  static void validate() {
    final uri = Uri.tryParse(supabaseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError(
        'SUPABASE_URL must be supplied as a valid HTTPS URL with '
        '--dart-define or --dart-define-from-file.',
      );
    }
    if (!isPublicSupabaseKey(supabasePublishableKey)) {
      throw StateError(
        'SUPABASE_PUBLISHABLE_KEY must be an anon or publishable key supplied '
        'with --dart-define or --dart-define-from-file. Secret keys are '
        'rejected because mobile bundles are public.',
      );
    }
    final redirect = authRedirectUri;
    if (redirect.scheme != 'morit' ||
        redirect.host != 'auth' ||
        redirect.path != '/callback') {
      throw StateError(
        'AUTH_REDIRECT_URI must match the allowlisted Android callback '
        'morit://auth/callback.',
      );
    }
    final downloadApi = downloadApiUri;
    if (downloadApiUrlValue.trim().isNotEmpty &&
        (downloadApi == null ||
            downloadApi.scheme != 'https' ||
            downloadApi.host.isEmpty ||
            downloadApi.userInfo.isNotEmpty ||
            downloadApi.hasQuery ||
            downloadApi.hasFragment)) {
      throw StateError(
        'DOWNLOAD_API_URL must be an HTTPS backend URL without credentials or '
        'a fragment. Server secrets must never be supplied to the app.',
      );
    }
  }

  /// Accepts Supabase publishable keys and legacy JWT anon keys only.
  ///
  /// This is a guardrail against accidentally compiling a server credential
  /// into the app. Authorization must still be enforced by RLS.
  static bool isPublicSupabaseKey(String value) {
    final key = value.trim();
    if (key.startsWith('sb_publishable_')) return key.length > 15;
    if (key.startsWith('sb_secret_') ||
        key.toLowerCase().contains('service_role')) {
      return false;
    }
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      return claims is Map<String, dynamic> && claims['role'] == 'anon';
    } on Object {
      return false;
    }
  }
}
