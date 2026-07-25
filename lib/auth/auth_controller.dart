import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_models.dart';

class MoringAuthController extends ChangeNotifier {
  MoringAuthController({
    required this.client,
    required this.config,
    DateTime Function()? now,
    this.resendCooldown = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now {
    _authSubscription = client.auth.onAuthStateChange.listen(
      _onAuthStateChanged,
      onError: _onAuthStreamError,
    );
    unawaited(refresh());
  }

  static const passwordResetNotice =
      '계정 존재 여부와 관계없이, 가입된 주소라면 비밀번호 재설정 메일을 보냈습니다.';

  final SupabaseClient client;
  final MoringAuthConfig config;
  final Duration resendCooldown;
  final DateTime Function() _now;

  late final StreamSubscription<AuthState> _authSubscription;
  MoringAuthState _state = const MoringAuthState();
  String? _mfaFactorId;
  int _routeVersion = 0;
  bool _recoveryMode = false;
  bool _routing = false;
  bool _routeAgain = false;
  bool _disposed = false;

  MoringAuthState get state => _state;
  Session? get session => client.auth.currentSession;
  User? get user => client.auth.currentUser;
  int get resendSecondsRemaining => _state.resendSecondsRemaining(_now());
  bool get canResend => _state.canResend(_now());

  Future<void> refresh() async {
    if (_disposed || _recoveryMode) return;
    if (session == null) {
      if (_state.stage == MoringAuthStage.checking) _showSignIn();
      return;
    }
    try {
      await _routeAuthenticatedUser();
    } on Object catch (error) {
      if (_disposed) return;
      _setState(
        _state.copyWith(
          stage: MoringAuthStage.signIn,
          busy: false,
          error: _friendlyError(error),
          notice: null,
        ),
      );
    }
  }

  void startRegistration() {
    if (_state.busy) return;
    if (session != null) {
      _showValidationError('현재 세션을 지운 뒤 다시 시도해 주세요.');
      return;
    }
    _setState(
      _state.copyWith(
        stage: MoringAuthStage.registerEmail,
        error: null,
        notice: null,
        pendingEmail: null,
        resendAvailableAt: null,
      ),
    );
  }

  void editRegistrationEmail() {
    if (_state.busy || session != null) return;
    _setState(
      _state.copyWith(
        stage: MoringAuthStage.registerEmail,
        error: null,
        notice: null,
        resendAvailableAt: null,
      ),
    );
  }

  void startPasswordReset() {
    if (_state.busy) return;
    if (session != null) {
      _showValidationError('현재 세션을 지운 뒤 다시 시도해 주세요.');
      return;
    }
    _setState(
      _state.copyWith(
        stage: MoringAuthStage.resetRequest,
        error: null,
        notice: null,
      ),
    );
  }

  Future<void> returnToSignIn() async {
    if (_state.busy) return;
    if (session != null) {
      await signOut();
    } else {
      _showSignIn();
    }
  }

  Future<void> signInWithPassword(String email, String password) async {
    final emailError = MoringAuthValidators.email(email);
    final passwordError = MoringAuthValidators.password(password);
    if (emailError != null || passwordError != null) {
      _showValidationError(emailError ?? passwordError!);
      return;
    }
    await _run(() async {
      final response = await client.auth.signInWithPassword(
        email: MoringAuthValidators.normalizeEmail(email),
        password: password,
      );
      if (response.session == null) {
        throw const AuthException('A session was not created.');
      }
      await _routeAuthenticatedUser();
    });
  }

  Future<void> signInWithGoogle() async {
    await _run(() async {
      final launched = await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: config.redirectUri.toString(),
      );
      if (!launched) throw StateError('OAuth browser did not open.');
      _setState(
        _state.copyWith(
          stage: MoringAuthStage.signIn,
          notice: '브라우저에서 Google 로그인을 완료해 주세요.',
        ),
      );
    });
  }

  Future<void> sendRegistrationOtp(String email) async {
    final validation = MoringAuthValidators.email(email);
    if (validation != null) {
      _showValidationError(validation);
      return;
    }
    final normalized = MoringAuthValidators.normalizeEmail(email);
    await _run(() async {
      await client.auth.signInWithOtp(
        email: normalized,
        emailRedirectTo: config.redirectUri.toString(),
        shouldCreateUser: true,
      );
      _setState(
        _state.copyWith(
          stage: MoringAuthStage.registerOtp,
          pendingEmail: normalized,
          resendAvailableAt: _now().add(resendCooldown),
          notice: '이메일로 보낸 6자리 코드를 입력해 주세요.',
        ),
      );
    });
  }

  Future<void> resendRegistrationOtp() async {
    final email = _state.pendingEmail;
    if (email == null || _state.stage != MoringAuthStage.registerOtp) return;
    final remaining = resendSecondsRemaining;
    if (remaining > 0) {
      _setState(_state.copyWith(notice: '$remaining초 후 다시 보낼 수 있습니다.'));
      return;
    }
    await _run(() async {
      await client.auth.signInWithOtp(
        email: email,
        emailRedirectTo: config.redirectUri.toString(),
        shouldCreateUser: true,
      );
      _setState(
        _state.copyWith(
          resendAvailableAt: _now().add(resendCooldown),
          notice: '새 인증 코드를 보냈습니다.',
        ),
      );
    });
  }

  Future<void> verifyRegistrationOtp(String code) async {
    final email = _state.pendingEmail;
    final validation = MoringAuthValidators.otp(code);
    if (email == null || _state.stage != MoringAuthStage.registerOtp) return;
    if (validation != null) {
      _showValidationError(validation);
      return;
    }
    await _run(() async {
      var sessionCreated = false;
      try {
        final response = await client.auth.verifyOTP(
          email: email,
          token: code.trim(),
          type: OtpType.email,
        );
        final verifiedUser = response.user;
        if (response.session == null || verifiedUser == null) {
          throw const AuthException(
            'OTP verification did not create a session.',
          );
        }
        sessionCreated = true;
        if (await _profileIsComplete(verifiedUser)) {
          await _signOutLocally();
          _recoveryMode = false;
          _mfaFactorId = null;
          _routeVersion++;
          _setState(
            const MoringAuthState(
              stage: MoringAuthStage.signIn,
              busy: true,
              notice: '이미 가입이 완료된 계정입니다. 로그인해 주세요.',
            ),
          );
          return;
        }
        _setState(
          _state.copyWith(
            stage: MoringAuthStage.onboarding,
            onboardingNeedsPassword: _usesEmailProvider(verifiedUser),
            pendingEmail: null,
            resendAvailableAt: null,
            notice: null,
          ),
        );
      } on Object {
        if (sessionCreated) {
          await _signOutLocally();
          _setState(
            _state.copyWith(
              stage: MoringAuthStage.registerEmail,
              pendingEmail: null,
              resendAvailableAt: null,
            ),
          );
        }
        rethrow;
      }
    });
  }

  Future<void> completeOnboarding({
    required String fullName,
    required String username,
    required String birthDate,
    String? password,
    required bool acceptedPolicies,
  }) async {
    final currentUser = user;
    if (_state.stage != MoringAuthStage.onboarding || currentUser == null) {
      return;
    }
    final validation =
        MoringAuthValidators.fullName(fullName) ??
        MoringAuthValidators.username(username) ??
        MoringAuthValidators.birthDate(birthDate, now: _now()) ??
        (_state.onboardingNeedsPassword
            ? MoringAuthValidators.password(password)
            : null) ??
        (acceptedPolicies ? null : '서비스 약관과 개인정보처리방침에 동의해 주세요.');
    if (validation != null) {
      _showValidationError(validation);
      return;
    }
    final parsedBirthDate = MoringAuthValidators.parseBirthDate(birthDate)!;
    final userId = currentUser.id;
    await _run(() async {
      if (_state.onboardingNeedsPassword) {
        try {
          await client.auth.updateUser(UserAttributes(password: password));
        } on AuthException catch (error) {
          if (error.code != 'same_password') rethrow;
        }
      }
      if (user?.id != userId) throw const AuthException('Session changed.');
      final metadata = currentUser.userMetadata;
      await client
          .schema(config.profilesSchema)
          .from(config.profilesTable)
          .upsert({
            'id': userId,
            'email': currentUser.email,
            'full_name': fullName.trim(),
            'username': username.trim(),
            'birth_date': _dateOnly(parsedBirthDate),
            'avatar_url': metadata?['avatar_url'] ?? metadata?['picture'],
            'updated_at': _now().toUtc().toIso8601String(),
          }, onConflict: 'id');
      if (user?.id != userId) throw const AuthException('Session changed.');
      await _routeAuthenticatedUser();
    });
  }

  Future<void> verifyMfa(String code) async {
    final validation = MoringAuthValidators.otp(code);
    if (validation != null) {
      _showValidationError(validation);
      return;
    }
    await _run(() async {
      var factorId = _mfaFactorId;
      factorId ??= (await client.auth.mfa.listFactors()).totp.firstOrNull?.id;
      if (factorId == null) {
        throw const AuthException('No verified TOTP factor is available.');
      }
      await client.auth.mfa.challengeAndVerify(
        factorId: factorId,
        code: code.trim(),
      );
      _mfaFactorId = null;
      await _routeAuthenticatedUser();
    });
  }

  Future<void> requestPasswordReset(String email) async {
    final validation = MoringAuthValidators.email(email);
    if (validation != null) {
      _showValidationError(validation);
      return;
    }
    if (_state.busy) return;
    _setState(_state.copyWith(busy: true, error: null, notice: null));
    String? error;
    try {
      await client.auth.resetPasswordForEmail(
        MoringAuthValidators.normalizeEmail(email),
        redirectTo: config.redirectUri.toString(),
      );
    } on AuthRetryableFetchException {
      error = '네트워크 연결을 확인하고 다시 시도해 주세요.';
    } on AuthException {
      // Keep account existence private even if the backend returns a distinct error.
    } on Object {
      error = '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.';
    }
    if (_disposed) return;
    _setState(
      _state.copyWith(
        stage: MoringAuthStage.resetRequest,
        busy: false,
        error: error,
        notice: error == null ? passwordResetNotice : null,
      ),
    );
  }

  Future<void> updateRecoveredPassword(String password) async {
    final validation = MoringAuthValidators.password(password);
    if (validation != null) {
      _showValidationError(validation);
      return;
    }
    if (_state.stage != MoringAuthStage.recoveryPassword || session == null) {
      _showValidationError('비밀번호 재설정 링크를 다시 요청해 주세요.');
      return;
    }
    await _run(() async {
      await client.auth.updateUser(UserAttributes(password: password));
      await _signOutLocally();
      _recoveryMode = false;
      _mfaFactorId = null;
      _routeVersion++;
      _setState(
        const MoringAuthState(
          stage: MoringAuthStage.signIn,
          busy: true,
          notice: '비밀번호를 변경했습니다. 새 비밀번호로 로그인해 주세요.',
        ),
      );
    });
  }

  Future<void> signOut() async {
    await _run(() async {
      _recoveryMode = false;
      _mfaFactorId = null;
      _routeVersion++;
      try {
        await client.auth.signOut(scope: SignOutScope.local);
      } finally {
        if (client.auth.currentSession == null) _showSignIn(busy: true);
      }
    });
  }

  Future<void> _routeAuthenticatedUser() async {
    if (_routing) {
      _routeAgain = true;
      return;
    }
    _routing = true;
    try {
      do {
        _routeAgain = false;
        await _routeAuthenticatedUserInner();
      } while (_routeAgain && !_disposed && !_recoveryMode);
    } finally {
      _routing = false;
    }
  }

  Future<void> _routeAuthenticatedUserInner() async {
    if (_recoveryMode || _disposed) return;
    final currentUser = user;
    if (currentUser == null) {
      _showSignIn();
      return;
    }
    final userId = currentUser.id;
    final version = ++_routeVersion;
    final assurance = client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (assurance.currentLevel != AuthenticatorAssuranceLevels.aal2) {
      final factors = await client.auth.mfa.listFactors();
      if (!_routeIsCurrent(version, userId)) return;
      final factor = factors.totp.firstOrNull;
      if (factor != null) {
        _mfaFactorId = factor.id;
        _setState(
          _state.copyWith(
            stage: MoringAuthStage.mfa,
            error: null,
            notice: null,
            pendingEmail: null,
            resendAvailableAt: null,
          ),
        );
        return;
      }
      final hasUnsupportedVerifiedFactor = factors.all.any(
        (factor) => factor.status == FactorStatus.verified,
      );
      if (hasUnsupportedVerifiedFactor) {
        await _signOutLocally();
        _routeVersion++;
        _setState(
          MoringAuthState(
            stage: MoringAuthStage.signIn,
            busy: _state.busy,
            error: '이 앱에서 지원하는 TOTP 2단계 인증 수단을 확인해 주세요.',
          ),
        );
        return;
      }
    }
    final latestUser = user;
    if (latestUser == null || !_routeIsCurrent(version, userId)) return;
    final complete = await _profileIsComplete(latestUser);
    if (!_routeIsCurrent(version, userId)) return;
    _mfaFactorId = null;
    _setState(
      _state.copyWith(
        stage: complete ? MoringAuthStage.ready : MoringAuthStage.onboarding,
        error: null,
        notice: null,
        pendingEmail: null,
        resendAvailableAt: null,
        onboardingNeedsPassword: !complete && _usesEmailProvider(latestUser),
      ),
    );
  }

  Future<bool> _profileIsComplete(User target) async {
    if (_usesEmailProvider(target) && target.emailConfirmedAt == null) {
      return false;
    }
    final value = await client
        .schema(config.profilesSchema)
        .from(config.profilesTable)
        .select('full_name,username,birth_date')
        .eq('id', target.id)
        .maybeSingle();
    if (value == null) return false;
    final profile = Map<String, dynamic>.from(value);
    return MoringAuthValidators.fullName(profile['full_name']?.toString()) ==
            null &&
        MoringAuthValidators.username(profile['username']?.toString()) ==
            null &&
        MoringAuthValidators.birthDate(
              profile['birth_date']?.toString(),
              now: _now(),
            ) ==
            null;
  }

  bool _usesEmailProvider(User target) {
    final provider = target.appMetadata['provider'];
    if (provider is String) return provider == 'email';
    final identities = target.identities ?? const <UserIdentity>[];
    return !identities.any((identity) => identity.provider != 'email');
  }

  bool _routeIsCurrent(int version, String userId) {
    return !_disposed &&
        !_recoveryMode &&
        version == _routeVersion &&
        user?.id == userId;
  }

  Future<void> _signOutLocally() async {
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } on Object {
      if (client.auth.currentSession != null) rethrow;
    }
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (_disposed || _state.busy) return false;
    _setState(_state.copyWith(busy: true, error: null, notice: null));
    var succeeded = false;
    try {
      await action();
      succeeded = true;
    } on Object catch (error) {
      if (!_disposed) {
        _setState(_state.copyWith(error: _friendlyError(error), notice: null));
      }
    } finally {
      if (!_disposed) _setState(_state.copyWith(busy: false));
    }
    return succeeded;
  }

  String _friendlyError(Object error) {
    if (error is AuthRetryableFetchException) {
      return '네트워크 연결을 확인하고 다시 시도해 주세요.';
    }
    if (error is PostgrestException && error.code == '23505') {
      return '이미 사용 중인 사용자명입니다.';
    }
    if (error is AuthException) {
      return switch (error.code) {
        'invalid_credentials' => '이메일 또는 비밀번호가 올바르지 않습니다.',
        'email_not_confirmed' => '이메일 인증을 먼저 완료해 주세요.',
        'otp_expired' => '인증 코드가 만료되었거나 올바르지 않습니다.',
        'mfa_verification_failed' ||
        'mfa_verification_rejected' ||
        'mfa_challenge_expired' => '인증 앱의 6자리 코드를 다시 확인해 주세요.',
        'over_email_send_rate_limit' ||
        'over_request_rate_limit' => '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
        'weak_password' => '더 안전한 비밀번호를 입력해 주세요.',
        'same_password' => '기존 비밀번호와 다른 비밀번호를 입력해 주세요.',
        'oauth_provider_not_supported' ||
        'provider_disabled' => '현재 Google 로그인을 사용할 수 없습니다.',
        _ => '요청을 완료하지 못했습니다. 입력 내용을 확인하고 다시 시도해 주세요.',
      };
    }
    return '요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.';
  }

  void _onAuthStateChanged(AuthState event) {
    if (_disposed) return;
    if (event.event == AuthChangeEvent.passwordRecovery) {
      _recoveryMode = true;
      _mfaFactorId = null;
      _routeVersion++;
      _setState(const MoringAuthState(stage: MoringAuthStage.recoveryPassword));
      return;
    }
    if (event.event == AuthChangeEvent.signedOut) {
      _recoveryMode = false;
      _mfaFactorId = null;
      _routeVersion++;
      _showSignIn(busy: _state.busy);
      return;
    }
    if (event.session == null) {
      if (_state.stage == MoringAuthStage.checking) _showSignIn();
      return;
    }
    final shouldRoute =
        event.event == AuthChangeEvent.initialSession ||
        event.event == AuthChangeEvent.signedIn ||
        event.event == AuthChangeEvent.mfaChallengeVerified;
    if (shouldRoute && !_state.busy && !_recoveryMode) {
      if (_routing) {
        _routeAgain = true;
      } else {
        unawaited(refresh());
      }
    }
  }

  void _onAuthStreamError(Object _) {
    if (_disposed) return;
    _setState(
      _state.copyWith(
        busy: false,
        error: '인증 상태를 확인하지 못했습니다. 네트워크 연결을 확인해 주세요.',
      ),
    );
  }

  void _showValidationError(String message) {
    if (_disposed) return;
    _setState(_state.copyWith(error: message, notice: null));
  }

  void _showSignIn({bool busy = false}) {
    _setState(MoringAuthState(stage: MoringAuthStage.signIn, busy: busy));
  }

  void _setState(MoringAuthState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  static String _dateOnly(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-${two(value.day)}';
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_authSubscription.cancel());
    super.dispose();
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
