import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'panel/panel_settings.dart';

/// Who is using this phone, sent with each command so the panel's events
/// (and every phone's activity log) can say who switched a machine.
class OperatorProfile extends ChangeNotifier {
  static const _nameKey = 'operator_name';
  static const _installKey = 'install_id';

  String _name = '';
  String _installId = '';

  /// The operator's name, or empty if not set.
  String get name => _name;

  /// A random tag for this app install, so its own commands can be told
  /// apart from other phones' when the panel reports them back.
  String get installId => _installId;

  /// The name to show for this phone's actions.
  String get displayName => _name.isEmpty ? 'This phone' : _name;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _name = prefs.getString(_nameKey) ?? '';
    _installId = prefs.getString(_installKey) ?? '';
    if (_installId.isEmpty) {
      _installId = PanelSettings.randomHex(8);
      await prefs.setString(_installKey, _installId);
    }
    notifyListeners();
  }

  /// Names are kept short and plain: they travel in every command.
  static String clean(String name) {
    final plain = name.replaceAll(RegExp(r'["\\\x00-\x1f\x7f]'), '').trim();
    return plain.length <= 32 ? plain : plain.substring(0, 32);
  }

  Future<void> setName(String name) async {
    _name = clean(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, _name);
    notifyListeners();
  }
}

final operatorProfile = OperatorProfile();
