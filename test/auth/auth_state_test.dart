import 'package:flutter_test/flutter_test.dart';
import 'package:morit/auth/moring_auth.dart';

void main() {
  test('config accepts safe app-owned endpoints and identifiers', () {
    final config = MoringAuthConfig(
      appName: ' Moring ',
      redirectUri: Uri.parse('moring://auth/callback'),
      profilesSchema: 'public',
      profilesTable: 'profiles_v2',
      privacyPolicyUrl: Uri.parse('https://example.com/privacy'),
      termsOfServiceUrl: Uri.parse('https://example.com/terms'),
    );

    expect(config.appName, 'Moring');
    expect(config.profilesSchema, 'public');
  });

  test('config rejects unsafe policy URLs and database identifiers', () {
    MoringAuthConfig build({
      String schema = 'public',
      String privacy = 'https://example.com/privacy',
    }) {
      return MoringAuthConfig(
        appName: 'Moring',
        redirectUri: Uri.parse('moring://auth/callback'),
        profilesSchema: schema,
        profilesTable: 'profiles',
        privacyPolicyUrl: Uri.parse(privacy),
        termsOfServiceUrl: Uri.parse('https://example.com/terms'),
      );
    }

    expect(() => build(schema: 'public;drop'), throwsArgumentError);
    expect(
      () => build(privacy: 'http://example.com/privacy'),
      throwsArgumentError,
    );
  });

  test('copyWith preserves values unless they are explicitly cleared', () {
    final resendAt = DateTime.utc(2026, 7, 23, 0, 0, 30);
    final state = MoringAuthState(
      stage: MoringAuthStage.registerOtp,
      error: 'error',
      notice: 'notice',
      pendingEmail: 'user@example.com',
      resendAvailableAt: resendAt,
    );

    final busy = state.copyWith(busy: true);
    expect(busy.error, 'error');
    expect(busy.pendingEmail, 'user@example.com');

    final cleared = busy.copyWith(error: null, notice: null);
    expect(cleared.error, isNull);
    expect(cleared.notice, isNull);
    expect(cleared.resendAvailableAt, resendAt);
  });

  test('resend cooldown rounds up and opens at the boundary', () {
    final availableAt = DateTime.utc(2026, 7, 23, 0, 0, 30);
    final state = MoringAuthState(resendAvailableAt: availableAt);

    expect(
      state.resendSecondsRemaining(DateTime.utc(2026, 7, 23, 0, 0, 0, 1)),
      30,
    );
    expect(state.canResend(DateTime.utc(2026, 7, 23, 0, 0, 29, 999)), isFalse);
    expect(state.canResend(availableAt), isTrue);
  });

  test('ready is represented by one explicit terminal stage', () {
    expect(const MoringAuthState(stage: MoringAuthStage.ready).isReady, isTrue);
    expect(const MoringAuthState().isReady, isFalse);
  });
}
