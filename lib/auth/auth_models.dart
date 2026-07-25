enum MoringAuthStage {
  checking,
  signIn,
  registerEmail,
  registerOtp,
  onboarding,
  mfa,
  resetRequest,
  recoveryPassword,
  ready,
}

class MoringAuthConfig {
  MoringAuthConfig({
    required String appName,
    required this.redirectUri,
    required String profilesSchema,
    required String profilesTable,
    required this.privacyPolicyUrl,
    required this.termsOfServiceUrl,
  }) : appName = appName.trim(),
       profilesSchema = profilesSchema.trim(),
       profilesTable = profilesTable.trim() {
    if (this.appName.isEmpty) {
      throw ArgumentError.value(appName, 'appName', 'must not be empty');
    }
    if (!redirectUri.hasScheme || redirectUri.toString().contains('#')) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'must be an absolute URI without a fragment',
      );
    }
    final identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    if (!identifier.hasMatch(this.profilesSchema)) {
      throw ArgumentError.value(
        profilesSchema,
        'profilesSchema',
        'must be a database identifier',
      );
    }
    if (!identifier.hasMatch(this.profilesTable)) {
      throw ArgumentError.value(
        profilesTable,
        'profilesTable',
        'must be a database identifier',
      );
    }
    if (privacyPolicyUrl.scheme != 'https') {
      throw ArgumentError.value(
        privacyPolicyUrl,
        'privacyPolicyUrl',
        'must use HTTPS',
      );
    }
    if (termsOfServiceUrl.scheme != 'https') {
      throw ArgumentError.value(
        termsOfServiceUrl,
        'termsOfServiceUrl',
        'must use HTTPS',
      );
    }
  }

  final String appName;
  final Uri redirectUri;
  final String profilesSchema;
  final String profilesTable;
  final Uri privacyPolicyUrl;
  final Uri termsOfServiceUrl;
}

const _notProvided = Object();

class MoringAuthState {
  const MoringAuthState({
    this.stage = MoringAuthStage.checking,
    this.busy = false,
    this.error,
    this.notice,
    this.pendingEmail,
    this.resendAvailableAt,
    this.onboardingNeedsPassword = false,
  });

  final MoringAuthStage stage;
  final bool busy;
  final String? error;
  final String? notice;
  final String? pendingEmail;
  final DateTime? resendAvailableAt;
  final bool onboardingNeedsPassword;

  bool get isReady => stage == MoringAuthStage.ready;

  int resendSecondsRemaining(DateTime now) {
    final availableAt = resendAvailableAt;
    if (availableAt == null || !availableAt.isAfter(now)) return 0;
    return (availableAt.difference(now).inMilliseconds + 999) ~/ 1000;
  }

  bool canResend(DateTime now) => resendSecondsRemaining(now) == 0;

  MoringAuthState copyWith({
    MoringAuthStage? stage,
    bool? busy,
    Object? error = _notProvided,
    Object? notice = _notProvided,
    Object? pendingEmail = _notProvided,
    Object? resendAvailableAt = _notProvided,
    bool? onboardingNeedsPassword,
  }) {
    return MoringAuthState(
      stage: stage ?? this.stage,
      busy: busy ?? this.busy,
      error: identical(error, _notProvided) ? this.error : error as String?,
      notice: identical(notice, _notProvided) ? this.notice : notice as String?,
      pendingEmail: identical(pendingEmail, _notProvided)
          ? this.pendingEmail
          : pendingEmail as String?,
      resendAvailableAt: identical(resendAvailableAt, _notProvided)
          ? this.resendAvailableAt
          : resendAvailableAt as DateTime?,
      onboardingNeedsPassword:
          onboardingNeedsPassword ?? this.onboardingNeedsPassword,
    );
  }
}

abstract final class MoringAuthValidators {
  static final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _usernamePattern = RegExp(r'^[A-Za-z0-9._\uAC00-\uD7A3]{3,30}$');
  static final _otpPattern = RegExp(r'^[0-9]{6}$');
  static final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  static String normalizeEmail(String value) => value.trim().toLowerCase();

  static String? email(String? value) {
    final input = value?.trim() ?? '';
    if (input.isEmpty) return '이메일을 입력해 주세요.';
    if (input.runes.length > 320 || !_emailPattern.hasMatch(input)) {
      return '올바른 이메일 주소를 입력해 주세요.';
    }
    return null;
  }

  static String? fullName(String? value) {
    final length = (value?.trim() ?? '').runes.length;
    if (length < 2 || length > 100) return '이름은 2~100자로 입력해 주세요.';
    return null;
  }

  static String? username(String? value) {
    final input = value?.trim() ?? '';
    if (!_usernamePattern.hasMatch(input) ||
        input.startsWith('.') ||
        input.endsWith('.') ||
        input.contains('..')) {
      return '사용자명은 한글, 영문, 숫자, 마침표, 밑줄로 3~30자여야 하며 마침표는 앞뒤나 연속으로 쓸 수 없습니다.';
    }
    return null;
  }

  static String? password(String? value) {
    final length = (value ?? '').runes.length;
    if (length < 8 || length > 128) {
      return '비밀번호는 8~128자로 입력해 주세요.';
    }
    return null;
  }

  static String? otp(String? value) {
    if (!_otpPattern.hasMatch(value?.trim() ?? '')) {
      return '6자리 숫자 코드를 입력해 주세요.';
    }
    return null;
  }

  static DateTime? parseBirthDate(String? value) {
    final match = _datePattern.firstMatch(value?.trim() ?? '');
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (year < 1) return null;
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }

  static String? birthDate(String? value, {DateTime? now}) {
    final parsed = parseBirthDate(value);
    if (parsed == null) return '생년월일을 YYYY-MM-DD 형식으로 입력해 주세요.';
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    if (parsed.isAfter(today)) return '미래 날짜는 입력할 수 없습니다.';
    return null;
  }
}
