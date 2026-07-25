import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class MoritPinStore {
  MoritPinStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String userId) => 'morit.today_pin.$userId';
  String _failuresKey(String userId) => '${_key(userId)}.failures';
  String _blockedKey(String userId) => '${_key(userId)}.blocked_until';

  Future<bool> hasPin(String userId) => _storage.containsKey(key: _key(userId));

  Future<bool> verify(String userId, String pin) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final blockedUntil = int.tryParse(
      await _storage.read(key: _blockedKey(userId)) ?? '',
    );
    if (blockedUntil != null && blockedUntil > now) return false;
    final valid = await _storage.read(key: _key(userId)) == pin;
    if (valid) {
      await _storage.delete(key: _failuresKey(userId));
      await _storage.delete(key: _blockedKey(userId));
      return true;
    }
    final failures =
        (int.tryParse(await _storage.read(key: _failuresKey(userId)) ?? '') ??
            0) +
        1;
    if (failures >= 5) {
      await _storage.write(
        key: _blockedKey(userId),
        value: '${now + const Duration(seconds: 30).inMilliseconds}',
      );
      await _storage.delete(key: _failuresKey(userId));
    } else {
      await _storage.write(key: _failuresKey(userId), value: '$failures');
    }
    return false;
  }

  Future<void> setPin(String userId, String pin) async {
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must contain 4 to 6 digits');
    }
    await Future.wait([
      _storage.write(key: _key(userId), value: pin),
      _storage.delete(key: _failuresKey(userId)),
      _storage.delete(key: _blockedKey(userId)),
    ]);
  }

  Future<void> clear(String userId) async {
    await Future.wait([
      _storage.delete(key: _key(userId)),
      _storage.delete(key: _failuresKey(userId)),
      _storage.delete(key: _blockedKey(userId)),
    ]);
  }
}
