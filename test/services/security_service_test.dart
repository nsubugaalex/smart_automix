import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_automix/services/security_service.dart';

void main() {
  late DateTime now;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime(2026, 1, 1, 8);
  });

  Future<SecurityService> load() async {
    final security = SecurityService(clock: () => now);
    await security.init();
    return security;
  }

  test('no PIN by default: control is unlocked', () async {
    final security = await load();
    expect(security.hasPin, isFalse);
    expect(security.requirePin, isFalse);
    expect(security.isUnlocked, isTrue);
  });

  test('PIN format is 4-6 digits', () {
    expect(SecurityService.isValidPin('1234'), isTrue);
    expect(SecurityService.isValidPin('123456'), isTrue);
    expect(SecurityService.isValidPin('123'), isFalse);
    expect(SecurityService.isValidPin('1234567'), isFalse);
    expect(SecurityService.isValidPin('12a4'), isFalse);
    expect(() => SecurityService().setPin('12'), throwsArgumentError);
  });

  test('setting a PIN persists and requires it after the unlock window',
      () async {
    final security = await load();
    await security.setPin('2468');
    expect(security.requirePin, isTrue);
    expect(security.isUnlocked, isTrue); // just set, so unlocked for now

    now = now.add(SecurityService.unlockDuration + const Duration(seconds: 1));
    expect(security.isUnlocked, isFalse);

    final reloaded = await load();
    expect(reloaded.requirePin, isTrue);
    expect(reloaded.isUnlocked, isFalse);
  });

  test('correct PIN unlocks for the unlock window, wrong PIN does not',
      () async {
    await (await load()).setPin('2468');
    final security = await load();

    expect(security.verifyPin('0000'), isFalse);
    expect(security.isUnlocked, isFalse);

    expect(security.verifyPin('2468'), isTrue);
    expect(security.isUnlocked, isTrue);

    now = now.add(SecurityService.unlockDuration + const Duration(seconds: 1));
    expect(security.isUnlocked, isFalse);
  });

  test('too many wrong attempts lock out even the correct PIN', () async {
    await (await load()).setPin('2468');
    final security = await load();

    for (var i = 0; i < SecurityService.maxFailedAttempts; i++) {
      expect(security.verifyPin('0000'), isFalse);
    }
    expect(security.lockoutRemaining, isNotNull);
    expect(security.verifyPin('2468'), isFalse);

    now = now.add(SecurityService.lockoutDuration + const Duration(seconds: 1));
    expect(security.lockoutRemaining, isNull);
    expect(security.verifyPin('2468'), isTrue);
  });

  test('restarting the app does not reset failed attempts or a lockout',
      () async {
    await (await load()).setPin('2468');

    var security = await load();
    for (var i = 0; i < SecurityService.maxFailedAttempts - 1; i++) {
      expect(security.verifyPin('0000'), isFalse);
    }
    await pumpEventQueue(); // let the background save finish
    security = await load();
    expect(security.verifyPin('0000'), isFalse); // the 5th wrong guess
    expect(security.lockoutRemaining, isNotNull);

    await pumpEventQueue();
    security = await load();
    expect(security.lockoutRemaining, isNotNull);
    expect(security.verifyPin('2468'), isFalse);
  });

  test('the PIN is stored as a salted hash, not in plain text', () async {
    final security = await load();
    await security.setPin('2468');

    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.values.any((v) => v.contains('2468')), isFalse);
    expect(stored['operator_pin_hash'], startsWith('pbkdf2-sha256\$'));
  });

  test('a plain-text PIN from an older version is migrated', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'operator_pin': '1357', 'require_pin': 'true'});
    final security = await load();

    expect(security.requirePin, isTrue);
    expect(security.verifyPin('1357'), isTrue);
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.containsKey('operator_pin'), isFalse);
  });

  test('disabling the PIN forgets it and unlocks control', () async {
    final security = await load();
    await security.setPin('2468');
    await security.disablePin();

    final reloaded = await load();
    expect(reloaded.hasPin, isFalse);
    expect(reloaded.requirePin, isFalse);
    expect(reloaded.isUnlocked, isTrue);
  });
}
