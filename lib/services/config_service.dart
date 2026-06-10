import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _kServerUrl      = 'server_url';
const _kEmpresaId      = 'empresa_id';
const _kEmpresaNombre  = 'empresa_nombre';
const _kUsuario        = 'usuario';
const _kTableFontSize  = 'table_font_size';
const _kTableFont      = 'table_font';
const _kTableFontBold  = 'table_font_bold';
const _kTableColumns   = 'table_columns';
const _kSortOrder      = 'sort_order';

// Legacy DBF mode
const _kLegacyMode          = 'legacy_mode';
const _kLegacyUsuarios      = 'legacy_usuarios';
const _kLegacySmbHost       = 'legacy_smb_host';
const _kLegacySmbShare      = 'legacy_smb_share';
const _kLegacySmbPath       = 'legacy_smb_path';
const _kLegacySmbUser       = 'legacy_smb_user';
const _kLegacySmbPass       = 'legacy_smb_pass';
const _kLegacyAlmacen       = 'legacy_almacen';
const _kLegacyEmpresaNombre = 'legacy_empresa_nombre';
const _kClaseNombres        = 'clase_nombres'; // Map<code, nombre> de CLASEART

const _kDefaultCols = [
  {'id': 'ubicacion',  'label': 'Ubicación',  'visible': true},
  {'id': 'codigo',     'label': 'Código',     'visible': true},
  {'id': 'articulo',   'label': 'Artículo',   'visible': true},
  {'id': 'stock',      'label': 'Stock',      'visible': true},
  {'id': 'inventario', 'label': 'Inventario', 'visible': true},
  {'id': 'proveedor',  'label': 'Proveedor',  'visible': true},
];

class ColConfig {
  final String id;
  final String label;
  final bool visible;

  const ColConfig({required this.id, required this.label, required this.visible});

  ColConfig copyWith({bool? visible}) =>
      ColConfig(id: id, label: label, visible: visible ?? this.visible);

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'visible': visible};

  factory ColConfig.fromJson(Map<String, dynamic> j) => ColConfig(
        id: j['id'] as String,
        label: j['label'] as String,
        visible: j['visible'] as bool? ?? true,
      );
}

class ConfigService {
  static late SharedPreferences _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String get serverUrl    => _prefs.getString(_kServerUrl) ?? '';
  static int    get empresaId    => _prefs.getInt(_kEmpresaId) ?? 0;
  static String get empresaNombre => _prefs.getString(_kEmpresaNombre) ?? '';
  static String get usuario      => _prefs.getString(_kUsuario) ?? '';
  static double get tableFontSize => _prefs.getDouble(_kTableFontSize) ?? 12.0;
  static String get tableFont     => _prefs.getString(_kTableFont) ?? 'Inter';
  static bool   get tableFontBold => _prefs.getBool(_kTableFontBold) ?? false;
  static String get sortOrder     => _prefs.getString(_kSortOrder) ?? 'ubicacion';

  static Future<void> saveSortOrder(String order) async {
    await _prefs.setString(_kSortOrder, order);
  }

  static List<ColConfig> get tableColumns {
    final stored = _prefs.getString(_kTableColumns);
    if (stored == null || stored.isEmpty) return _defaults();
    try {
      final decoded = jsonDecode(stored) as List;
      final storedIds = <String>{};
      final result = <ColConfig>[];
      for (final m in decoded) {
        final col = ColConfig.fromJson(Map<String, dynamic>.from(m as Map));
        result.add(col);
        storedIds.add(col.id);
      }
      for (final d in _kDefaultCols) {
        if (!storedIds.contains(d['id'])) {
          result.add(ColConfig.fromJson(Map<String, dynamic>.from(d)));
        }
      }
      return result;
    } catch (_) {
      return _defaults();
    }
  }

  static List<ColConfig> _defaults() =>
      _kDefaultCols.map((m) => ColConfig.fromJson(Map<String, dynamic>.from(m))).toList();

  // ── Legacy mode ───────────────────────────────────────────────────────────
  static bool   get isLegacyMode        => _prefs.getBool(_kLegacyMode) ?? false;
  static String get legacySmbHost       => _prefs.getString(_kLegacySmbHost) ?? '';
  static String get legacySmbShare      => _prefs.getString(_kLegacySmbShare) ?? '';
  static String get legacySmbPath       => _prefs.getString(_kLegacySmbPath) ?? '';
  static String get legacySmbUser       => _prefs.getString(_kLegacySmbUser) ?? 'guest';
  static String get legacySmbPass       => _prefs.getString(_kLegacySmbPass) ?? '';
  static String get legacyAlmacen       => _prefs.getString(_kLegacyAlmacen) ?? '1';
  static String get legacyEmpresaNombre => _prefs.getString(_kLegacyEmpresaNombre) ?? '';

  static List<String> get legacyUsuarios {
    final stored = _prefs.getString(_kLegacyUsuarios);
    if (stored == null || stored.isEmpty) return [];
    try {
      return List<String>.from(jsonDecode(stored) as List);
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveLegacyUsuarios(List<String> usuarios) async {
    await _prefs.setString(_kLegacyUsuarios, jsonEncode(usuarios));
  }

  static bool get isConfigured =>
      isLegacyMode
          ? legacySmbHost.isNotEmpty
          : serverUrl.isNotEmpty && empresaId > 0;

  static Future<void> save({
    required String serverUrl,
    required int empresaId,
    required String empresaNombre,
    required String usuario,
  }) async {
    await _prefs.setString(_kServerUrl, serverUrl);
    await _prefs.setInt(_kEmpresaId, empresaId);
    await _prefs.setString(_kEmpresaNombre, empresaNombre);
    await _prefs.setString(_kUsuario, usuario);
  }

  static Future<void> saveDisplay({
    required double tableFontSize,
    required String tableFont,
    required bool tableFontBold,
  }) async {
    await _prefs.setDouble(_kTableFontSize, tableFontSize);
    await _prefs.setString(_kTableFont, tableFont);
    await _prefs.setBool(_kTableFontBold, tableFontBold);
  }

  static Future<void> saveColumns(List<ColConfig> columns) async {
    await _prefs.setString(
        _kTableColumns, jsonEncode(columns.map((c) => c.toJson()).toList()));
  }

  static Future<void> saveLegacy({
    required bool legacyMode,
    required String smbHost,
    required String smbShare,
    required String smbPath,
    required String smbUser,
    required String smbPass,
    required String almacen,
  }) async {
    await _prefs.setBool(_kLegacyMode, legacyMode);
    await _prefs.setString(_kLegacySmbHost, smbHost);
    await _prefs.setString(_kLegacySmbShare, smbShare);
    await _prefs.setString(_kLegacySmbPath, smbPath);
    await _prefs.setString(_kLegacySmbUser, smbUser);
    await _prefs.setString(_kLegacySmbPass, smbPass);
    await _prefs.setString(_kLegacyAlmacen, almacen);
    // En modo legacy el empresaId no se usa; guardamos 0 para el filtro Drift
    if (legacyMode) await _prefs.setInt(_kEmpresaId, 0);
  }

  static Future<void> saveLegacyEmpresaNombre(String nombre) async {
    await _prefs.setString(_kLegacyEmpresaNombre, nombre);
  }

  static String apiUrl(String path) {
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return '$base$path';
  }

  // ── Backup / Restore ──────────────────────────────────────────────────────

  static Map<String, dynamic> exportToJson() => {
    _kLegacyMode:          isLegacyMode,
    _kServerUrl:           serverUrl,
    _kEmpresaId:           empresaId,
    _kEmpresaNombre:       empresaNombre,
    _kUsuario:             usuario,
    _kLegacySmbHost:       legacySmbHost,
    _kLegacySmbShare:      legacySmbShare,
    _kLegacySmbPath:       legacySmbPath,
    _kLegacySmbUser:       legacySmbUser,
    _kLegacySmbPass:       legacySmbPass,
    _kLegacyAlmacen:       legacyAlmacen,
    _kLegacyEmpresaNombre: legacyEmpresaNombre,
    _kLegacyUsuarios:      _prefs.getString(_kLegacyUsuarios) ?? '',
    _kTableFontSize:       tableFontSize,
    _kTableFont:           tableFont,
    _kTableFontBold:       tableFontBold,
    _kTableColumns:        _prefs.getString(_kTableColumns) ?? '',
    _kSortOrder:           sortOrder,
  };

  static Future<void> importFromJson(Map<String, dynamic> data) async {
    if (data[_kLegacyMode] is bool)  await _prefs.setBool  (_kLegacyMode,          data[_kLegacyMode] as bool);
    if (data[_kServerUrl]  is String && (data[_kServerUrl] as String).isNotEmpty)
                                      await _prefs.setString(_kServerUrl,            data[_kServerUrl] as String);
    if (data[_kEmpresaId]  is int)    await _prefs.setInt   (_kEmpresaId,            data[_kEmpresaId] as int);
    if (data[_kEmpresaNombre] is String) await _prefs.setString(_kEmpresaNombre,     data[_kEmpresaNombre] as String);
    if (data[_kUsuario]    is String) await _prefs.setString(_kUsuario,              data[_kUsuario] as String);
    if (data[_kLegacySmbHost]  is String) await _prefs.setString(_kLegacySmbHost,   data[_kLegacySmbHost] as String);
    if (data[_kLegacySmbShare] is String) await _prefs.setString(_kLegacySmbShare,  data[_kLegacySmbShare] as String);
    if (data[_kLegacySmbPath]  is String) await _prefs.setString(_kLegacySmbPath,   data[_kLegacySmbPath] as String);
    if (data[_kLegacySmbUser]  is String) await _prefs.setString(_kLegacySmbUser,   data[_kLegacySmbUser] as String);
    if (data[_kLegacySmbPass]  is String) await _prefs.setString(_kLegacySmbPass,   data[_kLegacySmbPass] as String);
    if (data[_kLegacyAlmacen]  is String) await _prefs.setString(_kLegacyAlmacen,   data[_kLegacyAlmacen] as String);
    if (data[_kLegacyEmpresaNombre] is String) await _prefs.setString(_kLegacyEmpresaNombre, data[_kLegacyEmpresaNombre] as String);
    if (data[_kLegacyUsuarios] is String && (data[_kLegacyUsuarios] as String).isNotEmpty)
                                      await _prefs.setString(_kLegacyUsuarios,       data[_kLegacyUsuarios] as String);
    if (data[_kTableFontSize] is num) await _prefs.setDouble(_kTableFontSize,        (data[_kTableFontSize] as num).toDouble());
    if (data[_kTableFont]  is String) await _prefs.setString(_kTableFont,            data[_kTableFont] as String);
    if (data[_kTableFontBold] is bool) await _prefs.setBool (_kTableFontBold,        data[_kTableFontBold] as bool);
    if (data[_kTableColumns] is String && (data[_kTableColumns] as String).isNotEmpty)
                                      await _prefs.setString(_kTableColumns,         data[_kTableColumns] as String);
    if (data[_kSortOrder]  is String) await _prefs.setString(_kSortOrder,            data[_kSortOrder] as String);
  }

  // ── Nombres de clases de artículo (cache de CLASEART.DBF) ─────────────────

  static Map<String, String> get claseNombres {
    try {
      final raw = _prefs.getString(_kClaseNombres) ?? '{}';
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) { return {}; }
  }

  static Future<void> saveClaseNombres(Map<String, String> nombres) async {
    await _prefs.setString(_kClaseNombres, jsonEncode(nombres));
  }

  /// Devuelve "CODE - NOMBRE" si hay nombre, o solo "CODE" si no.
  static String claseLabel(String code) {
    final trimmed = code.trim();
    final nombre  = claseNombres[trimmed];
    if (nombre == null || nombre.isEmpty || nombre == trimmed) return trimmed;
    return '$trimmed - $nombre';
  }
}
