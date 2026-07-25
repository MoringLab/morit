import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_controller.dart';
import 'auth_models.dart';

class MoringAuthGate extends StatelessWidget {
  const MoringAuthGate({
    super.key,
    required this.controller,
    required this.child,
    this.loading,
  });

  final MoringAuthController controller;
  final Widget child;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return switch (controller.state.stage) {
          MoringAuthStage.ready => child,
          MoringAuthStage.checking =>
            loading ??
                const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                ),
          _ => MoringAuthPage(controller: controller),
        };
      },
    );
  }
}

class MoringAuthPage extends StatefulWidget {
  const MoringAuthPage({super.key, required this.controller});

  final MoringAuthController controller;

  @override
  State<MoringAuthPage> createState() => _MoringAuthPageState();
}

class _MoringAuthPageState extends State<MoringAuthPage> {
  final email = TextEditingController();
  final loginPassword = TextEditingController();
  final otp = TextEditingController();
  final fullName = TextEditingController();
  final username = TextEditingController();
  final birthDate = TextEditingController();
  final onboardingPassword = TextEditingController();
  final onboardingPasswordConfirm = TextEditingController();
  final recoveredPassword = TextEditingController();
  final recoveredPasswordConfirm = TextEditingController();

  late MoringAuthStage lastStage = widget.controller.state.stage;
  late final Timer ticker;
  bool obscurePassword = true;
  bool acceptedPolicies = false;
  String? localError;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChange);
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          widget.controller.state.stage == MoringAuthStage.registerOtp) {
        setState(() {});
      }
    });
  }

  void _handleControllerChange() {
    final next = widget.controller.state.stage;
    if (next == lastStage) return;
    if (next == MoringAuthStage.registerOtp || next == MoringAuthStage.mfa) {
      otp.clear();
    }
    if (next == MoringAuthStage.onboarding) {
      fullName.clear();
      username.clear();
      birthDate.clear();
      onboardingPassword.clear();
      onboardingPasswordConfirm.clear();
      acceptedPolicies = false;
    }
    if (next == MoringAuthStage.recoveryPassword) {
      recoveredPassword.clear();
      recoveredPasswordConfirm.clear();
    }
    if (next == MoringAuthStage.signIn) {
      email.clear();
      loginPassword.clear();
      otp.clear();
      fullName.clear();
      username.clear();
      birthDate.clear();
      onboardingPassword.clear();
      onboardingPasswordConfirm.clear();
      recoveredPassword.clear();
      recoveredPasswordConfirm.clear();
      acceptedPolicies = false;
    }
    lastStage = next;
    localError = null;
  }

  @override
  void dispose() {
    ticker.cancel();
    widget.controller.removeListener(_handleControllerChange);
    for (final controller in [
      email,
      loginPassword,
      otp,
      fullName,
      username,
      birthDate,
      onboardingPassword,
      onboardingPasswordConfirm,
      recoveredPassword,
      recoveredPasswordConfirm,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        final copy = _copy(state.stage);
        return PopScope(
          canPop: state.stage == MoringAuthStage.signIn,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_handleBack(state.stage));
          },
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: CircleAvatar(
                              radius: 28,
                              child: const Icon(Icons.lock_outline_rounded),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            widget.controller.config.appName,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            copy.$1,
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            copy.$2,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  height: 1.45,
                                ),
                          ),
                          if (localError ?? state.error
                              case final message?) ...[
                            const SizedBox(height: 18),
                            _MessageBox(message: message, error: true),
                          ] else if (state.notice case final message?) ...[
                            const SizedBox(height: 18),
                            _MessageBox(message: message),
                          ],
                          const SizedBox(height: 26),
                          _formFor(state),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  (String, String) _copy(MoringAuthStage stage) => switch (stage) {
    MoringAuthStage.checking => ('계정을 확인하고 있어요', '잠시만 기다려 주세요.'),
    MoringAuthStage.signIn => ('다시 만나 반가워요', '이메일 또는 Google 계정으로 로그인하세요.'),
    MoringAuthStage.registerEmail => ('계정을 만들어요', '먼저 이메일 소유권을 확인합니다.'),
    MoringAuthStage.registerOtp => ('인증 코드를 확인해요', '이메일로 받은 6자리 숫자를 입력하세요.'),
    MoringAuthStage.onboarding => ('프로필을 완성해요', '필수 정보를 입력하면 바로 시작할 수 있어요.'),
    MoringAuthStage.mfa => ('2단계 인증이 필요해요', '인증 앱에 표시된 6자리 코드를 입력하세요.'),
    MoringAuthStage.resetRequest => (
      '비밀번호를 잊으셨나요?',
      '가입한 이메일로 안전한 재설정 링크를 보냅니다.',
    ),
    MoringAuthStage.recoveryPassword => (
      '새 비밀번호를 정해요',
      '8~128자의 새 비밀번호를 입력하세요.',
    ),
    MoringAuthStage.ready => ('로그인했어요', '앱으로 이동하고 있습니다.'),
  };

  Widget _formFor(MoringAuthState state) => switch (state.stage) {
    MoringAuthStage.signIn => _signInForm(state),
    MoringAuthStage.registerEmail => _registerEmailForm(state),
    MoringAuthStage.registerOtp => _registerOtpForm(state),
    MoringAuthStage.onboarding => _onboardingForm(state),
    MoringAuthStage.mfa => _mfaForm(state),
    MoringAuthStage.resetRequest => _resetRequestForm(state),
    MoringAuthStage.recoveryPassword => _recoveryPasswordForm(state),
    _ => const Center(child: CircularProgressIndicator()),
  };

  Widget _signInForm(MoringAuthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(),
        const SizedBox(height: 12),
        _passwordField(
          controller: loginPassword,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: state.busy ? null : _login,
          child: _buttonChild(state.busy, '로그인'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: state.busy
              ? null
              : () => _act(widget.controller.signInWithGoogle),
          icon: const Icon(Icons.open_in_browser_rounded),
          label: const Text('Google로 계속'),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed: state.busy
                  ? null
                  : () {
                      _clearLocalError();
                      widget.controller.startRegistration();
                    },
              child: const Text('계정 만들기'),
            ),
            TextButton(
              onPressed: state.busy
                  ? null
                  : () {
                      _clearLocalError();
                      widget.controller.startPasswordReset();
                    },
              child: const Text('비밀번호 재설정'),
            ),
          ],
        ),
        if (widget.controller.session != null)
          TextButton(
            onPressed: state.busy
                ? null
                : () => _act(widget.controller.signOut),
            child: const Text('현재 세션 지우기'),
          ),
      ],
    );
  }

  Widget _registerEmailForm(MoringAuthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(onSubmitted: (_) => _sendRegistrationOtp()),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: state.busy ? null : _sendRegistrationOtp,
          child: _buttonChild(state.busy, '인증 코드 받기'),
        ),
        TextButton(
          onPressed: state.busy
              ? null
              : () => _act(widget.controller.returnToSignIn),
          child: const Text('로그인으로 돌아가기'),
        ),
      ],
    );
  }

  Widget _registerOtpForm(MoringAuthState state) {
    final remaining = widget.controller.resendSecondsRemaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _otpField(onSubmitted: (_) => _verifyRegistrationOtp()),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: state.busy ? null : _verifyRegistrationOtp,
          child: _buttonChild(state.busy, '이메일 인증'),
        ),
        TextButton(
          onPressed: state.busy || remaining > 0
              ? null
              : () => _act(widget.controller.resendRegistrationOtp),
          child: Text(remaining > 0 ? '$remaining초 후 다시 보내기' : '인증 코드 다시 보내기'),
        ),
        TextButton(
          onPressed: state.busy
              ? null
              : () {
                  _clearLocalError();
                  widget.controller.editRegistrationEmail();
                },
          child: const Text('이메일 다시 입력'),
        ),
      ],
    );
  }

  Widget _onboardingForm(MoringAuthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _textField(
          controller: fullName,
          label: '이름',
          autofillHints: const [AutofillHints.name],
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        _textField(
          controller: username,
          label: '사용자명',
          helperText: '한글, 영문, 숫자, ._ · 3~30자 · 마침표 연속/앞뒤 불가',
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        _textField(
          controller: birthDate,
          label: '생년월일',
          hintText: 'YYYY-MM-DD',
          keyboardType: TextInputType.datetime,
          textInputAction: TextInputAction.next,
        ),
        if (state.onboardingNeedsPassword) ...[
          const SizedBox(height: 12),
          _passwordField(
            controller: onboardingPassword,
            label: '비밀번호',
            autofillHints: const [AutofillHints.newPassword],
          ),
          const SizedBox(height: 12),
          _passwordField(
            controller: onboardingPasswordConfirm,
            label: '비밀번호 확인',
            autofillHints: const [AutofillHints.newPassword],
            onSubmitted: (_) => _completeOnboarding(),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: acceptedPolicies,
              onChanged: state.busy
                  ? null
                  : (value) =>
                        setState(() => acceptedPolicies = value ?? false),
            ),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () =>
                        _openPolicy(widget.controller.config.termsOfServiceUrl),
                    child: const Text('서비스 약관'),
                  ),
                  const Text('및'),
                  TextButton(
                    onPressed: () =>
                        _openPolicy(widget.controller.config.privacyPolicyUrl),
                    child: const Text('개인정보처리방침'),
                  ),
                  const Text('에 동의합니다.'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: state.busy ? null : _completeOnboarding,
          child: _buttonChild(state.busy, '시작하기'),
        ),
        TextButton(
          onPressed: state.busy
              ? null
              : () => _act(widget.controller.returnToSignIn),
          child: const Text('로그아웃'),
        ),
      ],
    );
  }

  Widget _mfaForm(MoringAuthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _otpField(onSubmitted: (_) => _verifyMfa()),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: state.busy ? null : _verifyMfa,
          child: _buttonChild(state.busy, '2단계 인증'),
        ),
        TextButton(
          onPressed: state.busy
              ? null
              : () => _act(widget.controller.returnToSignIn),
          child: const Text('취소하고 로그인으로'),
        ),
      ],
    );
  }

  Widget _resetRequestForm(MoringAuthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _emailField(onSubmitted: (_) => _requestPasswordReset()),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: state.busy ? null : _requestPasswordReset,
          child: _buttonChild(state.busy, '재설정 메일 보내기'),
        ),
        TextButton(
          onPressed: state.busy
              ? null
              : () => _act(widget.controller.returnToSignIn),
          child: const Text('로그인으로 돌아가기'),
        ),
      ],
    );
  }

  Widget _recoveryPasswordForm(MoringAuthState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _passwordField(
          controller: recoveredPassword,
          label: '새 비밀번호',
          autofillHints: const [AutofillHints.newPassword],
        ),
        const SizedBox(height: 12),
        _passwordField(
          controller: recoveredPasswordConfirm,
          label: '새 비밀번호 확인',
          autofillHints: const [AutofillHints.newPassword],
          onSubmitted: (_) => _updateRecoveredPassword(),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: state.busy ? null : _updateRecoveredPassword,
          child: _buttonChild(state.busy, '비밀번호 변경'),
        ),
        TextButton(
          onPressed: state.busy
              ? null
              : () => _act(widget.controller.returnToSignIn),
          child: const Text('취소하고 로그인으로'),
        ),
      ],
    );
  }

  Widget _emailField({ValueChanged<String>? onSubmitted}) {
    return _textField(
      controller: email,
      label: '이메일',
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      textInputAction: onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onSubmitted: onSubmitted,
    );
  }

  Widget _otpField({required ValueChanged<String> onSubmitted}) {
    return _textField(
      controller: otp,
      label: '6자리 인증 코드',
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      onSubmitted: onSubmitted,
      inputFormatters: const [_SixDigitFormatter()],
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    String label = '비밀번호',
    Iterable<String>? autofillHints,
    ValueChanged<String>? onSubmitted,
  }) {
    return _textField(
      controller: controller,
      label: label,
      obscureText: obscurePassword,
      autofillHints: autofillHints,
      textInputAction: onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onSubmitted: onSubmitted,
      suffixIcon: IconButton(
        onPressed: () => setState(() => obscurePassword = !obscurePassword),
        tooltip: obscurePassword ? '비밀번호 보기' : '비밀번호 숨기기',
        icon: Icon(
          obscurePassword
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
        ),
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hintText,
    String? helperText,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    Iterable<String>? autofillHints,
    ValueChanged<String>? onSubmitted,
    bool obscureText = false,
    Widget? suffixIcon,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      obscureText: obscureText,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        helperText: helperText,
        suffixIcon: suffixIcon,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buttonChild(bool busy, String label) {
    return busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);
  }

  Future<void> _act(Future<void> Function() action) async {
    _clearLocalError();
    await action();
  }

  Future<void> _handleBack(MoringAuthStage stage) async {
    if (widget.controller.state.busy) return;
    _clearLocalError();
    if (stage == MoringAuthStage.registerOtp &&
        widget.controller.session == null) {
      widget.controller.editRegistrationEmail();
      return;
    }
    await widget.controller.returnToSignIn();
  }

  Future<void> _login() => _act(
    () => widget.controller.signInWithPassword(email.text, loginPassword.text),
  );

  Future<void> _sendRegistrationOtp() =>
      _act(() => widget.controller.sendRegistrationOtp(email.text));

  Future<void> _verifyRegistrationOtp() =>
      _act(() => widget.controller.verifyRegistrationOtp(otp.text));

  Future<void> _verifyMfa() =>
      _act(() => widget.controller.verifyMfa(otp.text));

  Future<void> _requestPasswordReset() =>
      _act(() => widget.controller.requestPasswordReset(email.text));

  Future<void> _completeOnboarding() async {
    if (widget.controller.state.onboardingNeedsPassword &&
        onboardingPassword.text != onboardingPasswordConfirm.text) {
      _showLocalError('비밀번호가 서로 일치하지 않습니다.');
      return;
    }
    await _act(
      () => widget.controller.completeOnboarding(
        fullName: fullName.text,
        username: username.text,
        birthDate: birthDate.text,
        password: onboardingPassword.text,
        acceptedPolicies: acceptedPolicies,
      ),
    );
  }

  Future<void> _updateRecoveredPassword() async {
    if (recoveredPassword.text != recoveredPasswordConfirm.text) {
      _showLocalError('비밀번호가 서로 일치하지 않습니다.');
      return;
    }
    await _act(
      () => widget.controller.updateRecoveredPassword(recoveredPassword.text),
    );
  }

  Future<void> _openPolicy(Uri url) async {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) _showLocalError('문서를 열지 못했습니다. 잠시 후 다시 시도해 주세요.');
  }

  void _clearLocalError() {
    if (localError != null && mounted) setState(() => localError = null);
  }

  void _showLocalError(String message) {
    if (mounted) setState(() => localError = message);
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          message,
          style: TextStyle(
            color: error
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _SixDigitFormatter extends TextInputFormatter {
  const _SixDigitFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp('[^0-9]'), '');
    final bounded = digits.length > 6 ? digits.substring(0, 6) : digits;
    return TextEditingValue(
      text: bounded,
      selection: TextSelection.collapsed(offset: bounded.length),
    );
  }
}
