import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Operator PIN that guards remotely switching machines on.
///
/// Switching machines *off* is never PIN-protected: stopping a machine is
/// the fail-safe direction, and an operator must always be able to cut
/// power in an emergency.
///
/// The PIN and the require-PIN flag live in [FlutterSecureStorage]
/// (Android Keystore / iOS Keychain backed). After a correct PIN, control
/// stays unlocked for [unlockDuration] so the operator isn't prompted on
/// every single switch. Repeated wrong guesses lock entry for
/// [lockoutDuration] to slow down brute-forcing a short PIN.
class SecurityService extends ChangeNotifier {
  SecurityService({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    DateTime Function() clock = DateTime.now,
  })  : _storage = storage,
        _clock = clock;

  static const _pinKey = 'operator_pin';
  static const _requirePinKey = 'require_pin';

  static const minPinLength = 4;
  static const maxPinLength = 6;
  static const unlockDuration = Duration(minutes: 2);
  static const maxFailedAttempts = 5;
  static const lockoutDuration = Duration(seconds: 60);

  final FlutterSecureStorage _storage;
  final DateTime Function() _clock;

  String? _pin;
  bool _requirePin = false;
  DateTime? _unlockedUntil;
  int _failedAttempts = 0;
  DateTime? _lockedOutUntil;

  bool get hasPin => _pin != null;
  bool get requirePin => _requirePin && hasPin;

  /// Whether switching machines on is currently allowed without a prompt.
  bool get isUnlocked =>
      !requirePin ||
      (_unlockedUntil != null && _clock().isBefore(_unlockedUntil!));

  /// Time left before PIN entry is allowed again (null if not locked out).
  Duration? get lockoutRemaining {
    if (_lockedOutUntil == null) return null;
    final remaining = _lockedOutUntil!.difference(_clock());
    return remaining.isNegative ? null : remaining;
  }

  Future<void> init() async {
    _pin = await _storage.read(key: _pinKey);
    _requirePin = await _storage.read(key: _requirePinKey) == 'true';
    notifyListeners();
  }

  /// Whether [pin] is an acceptable PIN format (4-6 digits).
  static bool isValidPin(String pin) =>
      pin.length >= minPinLength &&
      pin.length <= maxPinLength &&
      RegExp(r'^\d+$').hasMatch(pin);

  /// Check [pin]; on success, unlocks control for [unlockDuration].
  /// Always fails while locked out.
  bool verifyPin(String pin) {
    if (lockoutRemaining != null || _pin == null) return false;

    if (pin == _pin) {
      _failedAttempts = 0;
      _lockedOutUntil = null;
      _unlockedUntil = _clock().add(unlockDuration);
      notifyListeners();
      return true;
    }

    _failedAttempts++;
    if (_failedAttempts >= maxFailedAttempts) {
      _failedAttempts = 0;
      _lockedOutUntil = _clock().add(lockoutDuration);
    }
    notifyListeners();
    return false;
  }

  /// Set a new PIN and turn the PIN requirement on. Callers must have
  /// verified the current PIN first if one exists.
  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must be 4-6 digits');
    }
    _pin = pin;
    _requirePin = true;
    _unlockedUntil = _clock().add(unlockDuration);
    await _storage.write(key: _pinKey, value: pin);
    await _storage.write(key: _requirePinKey, value: 'true');
    notifyListeners();
  }

  /// Turn the PIN requirement off and forget the PIN. Callers must have
  /// verified the current PIN first.
  Future<void> disablePin() async {
    _pin = null;
    _requirePin = false;
    _unlockedUntil = null;
    await _storage.delete(key: _pinKey);
    await _storage.write(key: _requirePinKey, value: 'false');
    notifyListeners();
  }
}

final securityService = SecurityService();
