import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Operator PIN that guards remotely switching machines on.
///
/// Switching machines *off* is never PIN-protected: stopping a machine is
/// the fail-safe direction, and an operator must always be able to cut
/// power in an emergency.
///
/// The PIN (as a salted PBKDF2 hash, never the PIN itself) and the
/// require-PIN flag live in [FlutterSecureStorage] (Android Keystore / iOS
/// Keychain backed). After a correct PIN, control stays unlocked for
/// [unlockDuration] so the operator isn't prompted on every single switch.
/// Repeated wrong guesses lock entry for [lockoutDuration] to slow down
/// brute-forcing a short PIN; the failed-attempt count and lockout are
/// stored too, so restarting the app doesn't reset them.
class SecurityService extends ChangeNotifier {
  SecurityService({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    DateTime Function() clock = DateTime.now,
  })  : _storage = storage,
        _clock = clock;

  static const _pinHashKey = 'operator_pin_hash';
  static const _requirePinKey = 'require_pin';
  static const _failedAttemptsKey = 'pin_failed_attempts';
  static const _lockedOutUntilKey = 'pin_locked_out_until';

  /// Where older versions kept the PIN in plain text. Migrated on [init].
  static const _legacyPinKey = 'operator_pin';

  static const minPinLength = 4;
  static const maxPinLength = 6;
  static const unlockDuration = Duration(minutes: 2);
  static const maxFailedAttempts = 5;
  static const lockoutDuration = Duration(seconds: 60);

  static const _hashScheme = 'pbkdf2-sha256';
  static const _hashIterations = 20000;
  static const _saltLength = 16;

  final FlutterSecureStorage _storage;
  final DateTime Function() _clock;

  /// Stored as `pbkdf2-sha256$<iterations>$<salt hex>$<hash hex>`.
  String? _pinHash;
  bool _requirePin = false;
  DateTime? _unlockedUntil;
  int _failedAttempts = 0;
  DateTime? _lockedOutUntil;

  bool get hasPin => _pinHash != null;
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
    _pinHash = await _storage.read(key: _pinHashKey);
    final legacyPin = await _storage.read(key: _legacyPinKey);
    if (legacyPin != null) {
      if (_pinHash == null && isValidPin(legacyPin)) {
        _pinHash = _hashPin(legacyPin);
        await _storage.write(key: _pinHashKey, value: _pinHash);
      }
      await _storage.delete(key: _legacyPinKey);
    }
    _requirePin = await _storage.read(key: _requirePinKey) == 'true';
    _unlockedUntil = null; // a loaded PIN starts locked
    _failedAttempts =
        int.tryParse(await _storage.read(key: _failedAttemptsKey) ?? '') ?? 0;
    _lockedOutUntil =
        DateTime.tryParse(await _storage.read(key: _lockedOutUntilKey) ?? '');
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
    if (lockoutRemaining != null || _pinHash == null) return false;

    if (_matches(pin, _pinHash!)) {
      _failedAttempts = 0;
      _lockedOutUntil = null;
      _unlockedUntil = _clock().add(unlockDuration);
      unawaited(_saveAttempts());
      notifyListeners();
      return true;
    }

    _failedAttempts++;
    if (_failedAttempts >= maxFailedAttempts) {
      _failedAttempts = 0;
      _lockedOutUntil = _clock().add(lockoutDuration);
    }
    unawaited(_saveAttempts());
    notifyListeners();
    return false;
  }

  /// Set a new PIN and turn the PIN requirement on. Callers must have
  /// verified the current PIN first if one exists.
  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must be 4-6 digits');
    }
    _pinHash = _hashPin(pin);
    _requirePin = true;
    _unlockedUntil = _clock().add(unlockDuration);
    await _storage.write(key: _pinHashKey, value: _pinHash);
    await _storage.write(key: _requirePinKey, value: 'true');
    notifyListeners();
  }

  /// Turn the PIN requirement off and forget the PIN. Callers must have
  /// verified the current PIN first.
  Future<void> disablePin() async {
    _pinHash = null;
    _requirePin = false;
    _unlockedUntil = null;
    _failedAttempts = 0;
    _lockedOutUntil = null;
    await _storage.delete(key: _pinHashKey);
    await _storage.write(key: _requirePinKey, value: 'false');
    await _saveAttempts();
    notifyListeners();
  }

  Future<void> _saveAttempts() async {
    try {
      await _storage.write(
          key: _failedAttemptsKey, value: _failedAttempts.toString());
      if (_lockedOutUntil == null) {
        await _storage.delete(key: _lockedOutUntilKey);
      } else {
        await _storage.write(
            key: _lockedOutUntilKey, value: _lockedOutUntil!.toIso8601String());
      }
    } catch (e) {
      debugPrint('Could not save PIN attempts: $e');
    }
  }

  static String _hashPin(String pin) {
    final random = Random.secure();
    final salt = Uint8List.fromList(
        List.generate(_saltLength, (_) => random.nextInt(256)));
    final hash = _pbkdf2(pin, salt, _hashIterations);
    return '$_hashScheme\$$_hashIterations\$${_hex(salt)}\$${_hex(hash)}';
  }

  static bool _matches(String pin, String stored) {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != _hashScheme) return false;
    final iterations = int.tryParse(parts[1]);
    if (iterations == null || iterations <= 0) return false;
    final expected = _fromHex(parts[3]);
    final actual = _pbkdf2(pin, _fromHex(parts[2]), iterations);
    // Compare every byte so timing doesn't reveal how much matched.
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  /// PBKDF2-HMAC-SHA256 with a single 32-byte output block.
  static Uint8List _pbkdf2(String pin, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final result = Uint8List.fromList(block);
    for (var i = 1; i < iterations; i++) {
      block = hmac.convert(block).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= block[j];
      }
    }
    return result;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) => Uint8List.fromList([
        for (var i = 0; i + 1 < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
}

final securityService = SecurityService();
