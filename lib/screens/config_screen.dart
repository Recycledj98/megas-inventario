import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../build_info.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../database/database.dart';
import '../database/tables.dart';
import '../services/config_service.dart';
import '../services/feedback_service.dart';
import '../services/legacy_service.dart';
import '../services/sync_service.dart';
import '../widgets/app_toast.dart';

const _kFonts = [
  'Inter', 'Roboto', 'Open Sans', 'Lato', 'Nunito', 'Poppins',
  'DM Sans', 'Work Sans', 'Raleway', 'Source Code Pro',
  'Ubuntu Mono', 'Fira Code', 'IBM Plex Mono', 'Space Mono',
];
const _kSizes = [10.0, 11.0, 12.0, 13.0, 14.0, 15.0];
final _fmtDate = DateFormat('dd/MM/yyyy HH:mm');

class _EmpresaItem {
  final int id;
  final String nombre;
  const _EmpresaItem(this.id, this.nombre);
}

class ConfigScreen extends StatefulWidget {
  final bool isInitialSetup;
  const ConfigScreen({super.key, this.isInitialSetup = false});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _urlCtrl      = TextEditingController();
  final _usuarioCtrl  = TextEditingController();
  final _db           = AppDatabase();
  late final SyncService _sync;

  // ERP Windows (legacy) — modo por defecto
  bool _legacyMode    = true;
  bool _showApiMode   = false; // desbloquea el modo API (la "ruleta")

  final _smbHostCtrl  = TextEditingController();
  final _smbShareCtrl = TextEditingController();
  final _smbPathCtrl  = TextEditingController();
  final _smbUserCtrl  = TextEditingController();
  final _smbPassCtrl  = TextEditingController();
  String _legacyAlmacen   = '1';
  bool   _legacyTestando  = false;
  bool   _legacyConectado = false;
  String? _legacyError;
  List<String> _legacyUsuarios = [];
  late LegacyService _legacy;

  bool   _probando       = false;
  bool   _conectado      = false;
  String? _errorConexion;

  List<_EmpresaItem> _empresas      = [];
  _EmpresaItem?      _empresaSel;
  bool               _cargandoEmpresas = false;

  double         _fontSize   = 12.0;
  String         _fontFamily = 'Inter';
  bool           _fontBold   = false;
  List<ColConfig> _columns   = [];

  List<ArticulosLocalData> _previewArticulos = [];
  String _appVersion = '';
  CabecerasInventarioLocalData? _sesionPendiente;
  int    _lineasPendientes    = 0;
  bool   _syncing             = false;
  bool   _guardado            = false;
  String? _mensajeInventario;
  bool   _mensajeError        = false;

  late Dio _dio;

  String get _baseUrl {
    final u = _urlCtrl.text.trim();
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  bool get _canInventario =>
      _legacyMode ? ConfigService.legacySmbHost.isNotEmpty : ConfigService.serverUrl.isNotEmpty;

  bool get _canSave => _legacyMode
      ? (_smbHostCtrl.text.trim().isNotEmpty && _usuarioCtrl.text.trim().isNotEmpty)
      : (_conectado && _empresaSel != null && _usuarioCtrl.text.trim().isNotEmpty);

  @override
  void initState() {
    super.initState();
    _sync   = SyncService(_db);
    _legacy = LegacyService(_db);
    _dio    = Dio(BaseOptions(connectTimeout: const Duration(seconds: 6)));

    // Por defecto modo legacy; respetar configuración guardada si ya existe
    _legacyMode = ConfigService.isConfigured ? ConfigService.isLegacyMode : true;

    _legacyUsuarios     = List.from(ConfigService.legacyUsuarios);
    _smbHostCtrl.text   = ConfigService.legacySmbHost;
    _smbShareCtrl.text  = ConfigService.legacySmbShare;
    _smbPathCtrl.text   = ConfigService.legacySmbPath;
    _smbUserCtrl.text   = ConfigService.legacySmbUser;
    _smbPassCtrl.text   = ConfigService.legacySmbPass;
    _legacyAlmacen      = ConfigService.legacyAlmacen;
    _urlCtrl.text       = ConfigService.serverUrl;
    _usuarioCtrl.text   = ConfigService.usuario;
    _fontSize           = ConfigService.tableFontSize;
    _fontFamily         = ConfigService.tableFont;
    _fontBold           = ConfigService.tableFontBold;
    _columns            = List.from(ConfigService.tableColumns);

    // Si ya tiene host guardado, mostrar como conectado
    if (_legacyMode && ConfigService.legacySmbHost.isNotEmpty) {
      _legacyConectado = true;
    }

    _loadSesionPendiente();
    _loadPreviewArticulos();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _appVersion = i.version);
    });

    if (!_legacyMode && ConfigService.serverUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _probar());
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _usuarioCtrl.dispose();
    _smbHostCtrl.dispose();
    _smbShareCtrl.dispose();
    _smbPathCtrl.dispose();
    _smbUserCtrl.dispose();
    _smbPassCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _loadPreviewArticulos() async {
    if (!ConfigService.isConfigured) return;
    final eid = ConfigService.isLegacyMode ? 0 : ConfigService.empresaId;
    final arts = await _db.getArticulos(eid, sortOrder: 'ubicacion');
    if (mounted && arts.isNotEmpty) {
      setState(() => _previewArticulos = arts.take(2).toList());
    }
  }

  Future<void> _loadSesionPendiente() async {
    final eid = _legacyMode ? 0 : ConfigService.empresaId;
    if (!_legacyMode && eid <= 0) return;
    final pending = await _db.getPendientesSync(eid);
    if (pending.isEmpty) {
      if (mounted) setState(() { _sesionPendiente = null; _lineasPendientes = 0; });
      return;
    }
    final cab    = pending.first;
    final lineas = await _db.getLineas(cab.id);
    if (mounted) setState(() { _sesionPendiente = cab; _lineasPendientes = lineas.length; });
  }

  Future<void> _probar() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() { _probando = true; _conectado = false; _errorConexion = null; _empresas = []; _empresaSel = null; });
    try {
      final resp = await _dio.get('$_baseUrl/health');
      if (resp.statusCode == 200) {
        setState(() => _conectado = true);
        await _cargarEmpresas();
      }
    } on DioException catch (e) {
      setState(() => _errorConexion = _errDio(e));
    } finally {
      if (mounted) setState(() => _probando = false);
    }
  }

  Future<void> _cargarEmpresas() async {
    setState(() => _cargandoEmpresas = true);
    try {
      final resp  = await _dio.get('$_baseUrl/empresas');
      final items = (resp.data as List).map((j) => _EmpresaItem(
        j['empresa_id'] as int,
        j['razon_social'] as String? ?? j['nombre_comercial'] as String? ?? 'Empresa ${j['empresa_id']}',
      )).toList();
      _EmpresaItem? sel;
      if (ConfigService.empresaId > 0) {
        sel = items.where((e) => e.id == ConfigService.empresaId).firstOrNull;
      }
      sel ??= items.length == 1 ? items.first : null;
      if (mounted) setState(() { _empresas = items; _empresaSel = sel; });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _cargandoEmpresas = false);
    }
  }

  String _errDio(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
      return 'Tiempo agotado — verifica que el servidor esté activo';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'No se puede conectar — revisa la IP y el puerto';
    }
    return 'Error: ${e.message}';
  }

  Future<void> _doEnviar() async {
    final cab = _sesionPendiente;
    if (cab == null) { _showMsg('Sin sesión pendiente', error: true); return; }
    final lineas = await _db.getLineas(cab.id);
    if (lineas.isEmpty) { _showMsg('La sesión no tiene líneas contadas', error: true); return; }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar envío'),
        content: Text('¿Enviar ${lineas.length} línea(s) al servidor?\nEsto actualizará los stocks en el ERP y cerrará la sesión.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enviar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() { _syncing = true; _mensajeInventario = null; });
    try {
      if (_legacyMode) {
        final result = await _legacy.enviar(cab, lineas);
        await _db.cerrarCabecera(cab.id);
        if (mounted) {
          _showMsg('Enviado: ${result.inventariados} artículos, ${result.movimientos} movimientos E/S');
          await _loadSesionPendiente();
        }
      } else {
        final servidorId = await _sync.sendInventario(cab, lineas);
        await _db.marcarCabeceraSync(cab.id, servidorId);
        if (mounted) { _showMsg('Enviado: ${lineas.length} líneas'); await _loadSesionPendiente(); }
      }
    } catch (e) {
      if (mounted) _showMsg('Error al enviar: $e', error: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _mostrarFiltrosYRecibir() async {
    final filtros = await showDialog<_RecibirFiltros>(
      context: context,
      builder: (_) => _DialogFiltrosRecibir(
        db: _db,
        empresaId: _legacyMode ? 0 : ConfigService.empresaId,
      ),
    );
    if (filtros == null || !mounted) return;
    await _doRecibir(filtros: filtros);
  }

  Future<void> _doRecibir({_RecibirFiltros? filtros}) async {
    setState(() { _syncing = true; _mensajeInventario = null; });
    try {
      if (_legacyMode) {
        final pendientes = await _db.getPendientesSync(0);
        for (final c in pendientes) await _db.cerrarCabecera(c.id);
        final result = await _legacy.recibir(filtros: filtros != null
            ? LegacyFiltros(proveedor: filtros.proveedor, familia: filtros.familia, tipos: filtros.tipos)
            : null);
        if (result.empresaNombre.isNotEmpty) {
          await ConfigService.saveLegacyEmpresaNombre(result.empresaNombre);
        }
        if (result.usuarios.isNotEmpty) {
          await ConfigService.saveLegacyUsuarios(result.usuarios);
          if (mounted) setState(() => _legacyUsuarios = result.usuarios);
        }
        if (mounted) {
          _showMsg('Recibido: ${result.articulos} artículos, ${result.lotes} lotes');
          await _loadSesionPendiente();
        }
      } else {
        final result = await _sync.syncStock();
        if (_sesionPendiente != null) await _db.cerrarCabecera(_sesionPendiente!.id);
        if (mounted) { _showMsg('Stock recibido: ${result.stockLotes} registros'); await _loadSesionPendiente(); }
      }
    } catch (e) {
      if (mounted) _showMsg('Error al recibir: $e', error: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _showMsg(String msg, {bool error = false}) {
    setState(() { _mensajeInventario = msg; _mensajeError = error; });
    AppToast.show(context, msg, error: error);
  }

  Future<void> _doProbarLegacy() async {
    setState(() { _legacyTestando = true; _legacyConectado = false; _legacyError = null; });
    try {
      await ConfigService.saveLegacy(
        legacyMode: true,
        smbHost: _smbHostCtrl.text.trim(),
        smbShare: _smbShareCtrl.text.trim(),
        smbPath: _smbPathCtrl.text.trim(),
        smbUser: _smbUserCtrl.text.trim(),
        smbPass: _smbPassCtrl.text.trim(),
        almacen: _legacyAlmacen,
      );
      final result = await LegacyService(_db).recibir();
      if (result.usuarios.isNotEmpty) {
        await ConfigService.saveLegacyUsuarios(result.usuarios);
        if (mounted) setState(() => _legacyUsuarios = result.usuarios);
      }
      if (mounted) setState(() => _legacyConectado = true);
    } catch (e) {
      if (mounted) setState(() => _legacyError = e.toString());
    } finally {
      if (mounted) setState(() => _legacyTestando = false);
    }
  }

  Future<void> _guardarLegacy() async {
    if (_smbHostCtrl.text.trim().isEmpty) {
      _showMsg('Introduce la IP o nombre del servidor', error: true);
      return;
    }
    if (_usuarioCtrl.text.trim().isEmpty) {
      _showMsg('Introduce tu nombre de usuario', error: true);
      return;
    }
    await ConfigService.saveLegacy(
      legacyMode: true,
      smbHost:  _smbHostCtrl.text.trim(),
      smbShare: _smbShareCtrl.text.trim(),
      smbPath:  _smbPathCtrl.text.trim(),
      smbUser:  _smbUserCtrl.text.trim(),
      smbPass:  _smbPassCtrl.text.trim(),
      almacen:  _legacyAlmacen,
    );
    await ConfigService.save(
      serverUrl: '',
      empresaId: 0,
      empresaNombre: 'GC Legacy',
      usuario: _usuarioCtrl.text.trim(),
    );
    await ConfigService.saveDisplay(tableFontSize: _fontSize, tableFont: _fontFamily, tableFontBold: _fontBold);
    await ConfigService.saveColumns(_columns);
    if (!mounted) return;
    if (widget.isInitialSetup) {
      context.go('/');
    } else {
      setState(() => _guardado = true);
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) context.pop();
    }
  }

  Future<void> _guardar() async {
    if (_legacyMode) { await _guardarLegacy(); return; }
    if (_usuarioCtrl.text.trim().isEmpty) {
      AppToast.show(context, 'Introduce tu nombre de usuario', error: true);
      return;
    }
    if (_empresaSel == null) {
      AppToast.show(context, 'Selecciona una empresa', error: true);
      return;
    }
    await ConfigService.save(
      serverUrl: _baseUrl,
      empresaId: _empresaSel!.id,
      empresaNombre: _empresaSel!.nombre,
      usuario: _usuarioCtrl.text.trim(),
    );
    await ConfigService.saveDisplay(tableFontSize: _fontSize, tableFont: _fontFamily, tableFontBold: _fontBold);
    await ConfigService.saveColumns(_columns);
    if (!mounted) return;
    if (widget.isInitialSetup) {
      context.go('/');
    } else {
      setState(() => _guardado = true);
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) context.pop();
    }
  }

  // ── Root build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    if (widget.isInitialSetup) return _buildWizard(theme, cs);
    return _buildMainScreen(theme, cs);
  }

  // ── Pantalla principal ──────────────────────────────────────────────────────

  Widget _buildMainScreen(ThemeData theme, ColorScheme cs) {
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        title: const Text('CONFIGURACIÓN'),
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
          letterSpacing: 1.0,
        ),
        actions: [
          if (_canSave)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _guardado
                    ? FilledButton.icon(
                        key: const ValueKey('saved'),
                        onPressed: null,
                        icon: const Icon(Symbols.check, size: 18),
                        label: const Text('Guardado'),
                        style: FilledButton.styleFrom(backgroundColor: Colors.green.shade600),
                      )
                    : FilledButton.icon(
                        key: const ValueKey('save'),
                        onPressed: _guardar,
                        icon: const Icon(Symbols.save, size: 18),
                        label: const Text('Guardar'),
                      ),
              ),
            ),
          // La "ruleta" — acceso oculto al modo API
          IconButton(
            icon: Icon(
              Symbols.settings,
              size: 20,
              color: _showApiMode
                  ? cs.primary
                  : cs.onSurfaceVariant.withAlpha(70),
            ),
            tooltip: 'Opciones avanzadas',
            onPressed: () => setState(() => _showApiMode = !_showApiMode),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (ctx, c) => c.maxWidth > 700
            ? _buildWideBody(theme, cs)
            : _buildNarrowBody(theme, cs),
      ),
    );
  }

  // ── Layout ancho (tablet landscape) ────────────────────────────────────────

  Widget _buildWideBody(ThemeData theme, ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Izquierda: acciones de inventario (uso diario)
        SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 10, 20),
            child: _buildInventarioCard(theme, cs),
          ),
        ),
        // Derecha: configuración
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _buildConfigSections(theme, cs),
            ),
          ),
        ),
      ],
    );
  }

  // ── Layout estrecho (portrait) ──────────────────────────────────────────────

  Widget _buildNarrowBody(ThemeData theme, ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildInventarioCard(theme, cs),
          const SizedBox(height: 16),
          ..._buildConfigSections(theme, cs),
        ],
      ),
    );
  }

  List<Widget> _buildConfigSections(ThemeData theme, ColorScheme cs) {
    return [
      // Modo API oculto — solo visible si se pulsó la ruleta
      if (_showApiMode) ...[
        _buildApiModeCard(theme, cs),
        const SizedBox(height: 16),
      ],

      if (_legacyMode) ...[
        _buildErpCard(theme, cs),
        const SizedBox(height: 16),
        _buildUsuarioCard(theme, cs),
      ] else ...[
        _buildConexionApiCard(theme, cs),
        if (_conectado) ...[
          const SizedBox(height: 16),
          _buildEmpresaUsuarioCard(theme, cs),
        ],
      ],

      const SizedBox(height: 16),
      _buildVisualizacionCard(theme, cs),
      const SizedBox(height: 16),
      _buildColumnasCard(theme, cs),
      const SizedBox(height: 16),
      _buildAcercaDeCard(theme, cs),
    ];
  }

  // ── Tarjeta: Inventario ─────────────────────────────────────────────────────

  Widget _buildInventarioCard(ThemeData theme, ColorScheme cs) {
    final hasSesion = _sesionPendiente != null;

    return _Card(
      icon: Symbols.inventory_2,
      title: 'Inventario',
      accentColor: cs.primary,
      theme: theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Estado sesión
          _SesionStatus(
            sesion: _sesionPendiente,
            lineas: _lineasPendientes,
            theme: theme,
          ),

          if (_mensajeInventario != null) ...[
            const SizedBox(height: 10),
            _MsgBanner(msg: _mensajeInventario!, isError: _mensajeError, theme: theme),
          ],

          const SizedBox(height: 16),

          // Botón ENVIAR
          FilledButton(
            onPressed: (_canInventario && hasSesion && !_syncing) ? _doEnviar : null,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: _syncing
                ? _LoadingRow(label: 'Procesando...', color: cs.onPrimary)
                : const _BtnRow(icon: Symbols.upload, label: 'Enviar inventario'),
          ),

          const SizedBox(height: 10),

          // Botón RECIBIR
          OutlinedButton(
            onPressed: (_canInventario && !_syncing) ? _mostrarFiltrosYRecibir : null,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: const _BtnRow(icon: Symbols.download, label: 'Recibir inventario'),
          ),

          if (!_canInventario) ...[
            const SizedBox(height: 10),
            Text(
              'Configura la conexión para habilitar estas opciones',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  // ── Tarjeta: ERP Windows (conexión SMB) ─────────────────────────────────────

  Widget _buildErpCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.storage,
      title: 'Conexión',
      accentColor: _legacyConectado ? Colors.green.shade600 : cs.onSurfaceVariant,
      theme: theme,
      trailing: _legacyConectado
          ? _Badge(label: 'Conectado', color: Colors.green.shade600)
          : _legacyError != null
              ? _Badge(label: 'Error', color: cs.error)
              : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Servidor + Carpeta en fila
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _Field(
                  ctrl: _smbHostCtrl,
                  label: 'Servidor',
                  hint: '192.168.1.100 o SERVIDOR',
                  icon: Symbols.computer,
                  onChanged: (_) => setState(() => _legacyConectado = false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _Field(
                  ctrl: _smbShareCtrl,
                  label: 'Carpeta compartida',
                  hint: 'MEGAS',
                  onChanged: (_) => setState(() => _legacyConectado = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Field(
            ctrl: _smbPathCtrl,
            label: 'Subcarpeta (opcional)',
            hint: 'GC',
            icon: Symbols.folder,
            onChanged: (_) => setState(() => _legacyConectado = false),
          ),
          const SizedBox(height: 10),
          // Usuario SMB + Contraseña
          Row(
            children: [
              Expanded(
                child: _Field(
                  ctrl: _smbUserCtrl,
                  label: 'Usuario Windows',
                  hint: 'guest',
                  icon: Symbols.person,
                  onChanged: (_) => setState(() => _legacyConectado = false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  ctrl: _smbPassCtrl,
                  label: 'Contraseña',
                  icon: Symbols.lock,
                  obscure: true,
                  onChanged: (_) => setState(() => _legacyConectado = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Almacén + Botón probar
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _legacyAlmacen,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Almacén',
                    prefixIcon: const Icon(Symbols.warehouse, size: 20),
                  ),
                  items: [
                    for (int i = 1; i <= 5; i++)
                      DropdownMenuItem(
                        value: '$i',
                        child: Text('Almacén $i', style: TextStyle(color: cs.onSurface)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _legacyAlmacen = v ?? '1'),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 56,
                child: FilledButton.tonal(
                  onPressed: _legacyTestando ? null : _doProbarLegacy,
                  child: _legacyTestando
                      ? SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
                      : const Text('Conectar'),
                ),
              ),
            ],
          ),

          if (_legacyError != null) ...[
            const SizedBox(height: 10),
            _ErrorBox(msg: _legacyError!, theme: theme),
          ],
        ],
      ),
    );
  }

  // ── Tarjeta: Usuario ────────────────────────────────────────────────────────

  Widget _buildUsuarioCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.person,
      title: 'Usuario',
      accentColor: cs.secondary,
      theme: theme,
      child: _legacyUsuarios.isNotEmpty
          ? DropdownButtonFormField<String>(
              value: _legacyUsuarios.contains(_usuarioCtrl.text.trim())
                  ? _usuarioCtrl.text.trim()
                  : null,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Selecciona tu usuario',
                prefixIcon: Icon(Symbols.person, size: 20),
              ),
              items: _legacyUsuarios
                  .map((u) => DropdownMenuItem(
                        value: u,
                        child: Text(u, style: TextStyle(color: cs.onSurface)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _usuarioCtrl.text = v);
              },
            )
          : _Field(
              ctrl: _usuarioCtrl,
              label: 'Nombre de usuario',
              icon: Symbols.person,
            ),
    );
  }

  // ── Tarjeta: Modo API (oculta, detrás de la ruleta) ────────────────────────

  Widget _buildApiModeCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.cloud_sync,
      title: 'Modo de conexión',
      accentColor: cs.tertiary,
      theme: theme,
      subtitle: 'Opciones avanzadas',
      child: Row(
        children: [
          Expanded(
            child: _ModeTile(
              icon: Symbols.storage,
              title: 'Megas Windows',
              subtitle: 'SMB directo',
              selected: _legacyMode,
              onTap: () => setState(() => _legacyMode = true),
              theme: theme,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ModeTile(
              icon: Symbols.cloud_sync,
              title: 'API MegasWeb',
              subtitle: 'FastAPI / REST',
              selected: !_legacyMode,
              onTap: () => setState(() => _legacyMode = false),
              theme: theme,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tarjeta: Conexión API ───────────────────────────────────────────────────

  Widget _buildConexionApiCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.dns,
      title: 'Conexión al servidor',
      accentColor: _conectado ? Colors.green.shade600 : cs.onSurfaceVariant,
      theme: theme,
      trailing: _conectado
          ? _Badge(label: 'Conectado', color: Colors.green.shade600)
          : _errorConexion != null
              ? _Badge(label: 'Error', color: cs.error)
              : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Field(
                  ctrl: _urlCtrl,
                  label: 'URL del servidor',
                  hint: 'http://192.168.1.100:8000',
                  icon: Symbols.language,
                  keyboard: TextInputType.url,
                  onSubmitted: (_) => _probar(),
                  trailing: _conectado
                      ? const Icon(Symbols.check_circle, color: Colors.green, size: 20)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _probando ? null : _probar,
                  child: _probando
                      ? SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
                      : const Text('Probar'),
                ),
              ),
            ],
          ),
          if (_errorConexion != null) ...[
            const SizedBox(height: 10),
            _ErrorBox(msg: _errorConexion!, theme: theme),
          ],
        ],
      ),
    );
  }

  // ── Tarjeta: Empresa + Usuario (modo API) ────────────────────────────────────

  Widget _buildEmpresaUsuarioCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.business,
      title: 'Empresa y usuario',
      accentColor: cs.secondary,
      theme: theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cargandoEmpresas)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_empresas.isNotEmpty)
            DropdownButtonFormField<_EmpresaItem>(
              value: _empresaSel,
              style: TextStyle(color: cs.onSurface, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Empresa',
                prefixIcon: Icon(Symbols.apartment, size: 20),
              ),
              items: _empresas
                  .map((e) => DropdownMenuItem(
                        value: e,
                        child: Text(e.nombre,
                            style: TextStyle(color: cs.onSurface, fontSize: 14),
                            overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _empresaSel = v),
            )
          else
            Text('Sin empresas disponibles',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 14),
          _Field(ctrl: _usuarioCtrl, label: 'Nombre de usuario', icon: Symbols.person),
        ],
      ),
    );
  }

  // ── Tarjeta: Visualización ─────────────────────────────────────────────────

  TextStyle _previewStyle() {
    try {
      return GoogleFonts.getFont(
        _fontFamily,
        fontSize: _fontSize,
        fontWeight: _fontBold ? FontWeight.w700 : FontWeight.w400,
      );
    } catch (_) {
      return TextStyle(
        fontSize: _fontSize,
        fontWeight: _fontBold ? FontWeight.w700 : FontWeight.w400,
      );
    }
  }

  Widget _buildVisualizacionCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.text_fields,
      title: 'Aspecto de la tabla',
      accentColor: cs.tertiary,
      theme: theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<double>(
                  value: _fontSize,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Tamaño texto',
                    prefixIcon: Icon(Symbols.format_size, size: 20),
                  ),
                  items: _kSizes
                      .map((s) => DropdownMenuItem(
                            value: s,
                            child: Text('${s.toInt()} pt',
                                style: TextStyle(color: cs.onSurface, fontSize: 14)),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _fontSize = v ?? 12.0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  value: _fontFamily,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Fuente',
                    prefixIcon: Icon(Symbols.font_download, size: 20),
                  ),
                  items: _kFonts
                      .map((f) => DropdownMenuItem(
                            value: f,
                            child: Text(f,
                                style: TextStyle(color: cs.onSurface, fontSize: 14),
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _fontFamily = v ?? 'Inter'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Symbols.format_bold, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('Negrita', style: TextStyle(fontSize: 13, color: cs.onSurface)),
              const Spacer(),
              Switch(value: _fontBold, onChanged: (v) => setState(() => _fontBold = v)),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Previsualización',
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                ...(_previewArticulos.isEmpty
                    ? [
                        Text('REF-001234   Tornillo M6 inox 304',
                            style: _previewStyle().copyWith(color: cs.onSurface),
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text('ART005   Moritz Botella 33cl x24',
                            style: _previewStyle().copyWith(color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis),
                      ]
                    : [
                        for (int i = 0; i < _previewArticulos.length; i++) ...[
                          if (i > 0) const SizedBox(height: 2),
                          Text(
                            '${_previewArticulos[i].identificacion}   '
                            '${_previewArticulos[i].descripcion1 ?? _previewArticulos[i].descripcion2 ?? ''}',
                            style: _previewStyle().copyWith(
                              color: i == 0 ? cs.onSurface : cs.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Tarjeta: Columnas ───────────────────────────────────────────────────────

  Widget _buildColumnasCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.view_column,
      title: 'Columnas de tabla',
      subtitle: 'Arrastra para reordenar',
      accentColor: cs.onSurfaceVariant,
      theme: theme,
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
          onReorder: (oldIdx, newIdx) {
            setState(() {
              if (newIdx > oldIdx) newIdx--;
              final item = _columns.removeAt(oldIdx);
              _columns.insert(newIdx, item);
            });
          },
          children: [
            for (final col in _columns)
              Material(
                key: ValueKey(col.id),
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Symbols.drag_indicator,
                      color: cs.onSurfaceVariant.withAlpha(120), size: 20),
                  title: Text(col.label,
                      style: TextStyle(fontSize: 13, color: cs.onSurface),
                      overflow: TextOverflow.ellipsis),
                  trailing: Switch(
                    value: col.visible,
                    onChanged: (v) {
                      setState(() {
                        final idx = _columns.indexWhere((c) => c.id == col.id);
                        _columns[idx] = col.copyWith(visible: v);
                      });
                    },
                  ),
                ),
              ),
          ],
        ),
    );
  }

  // ── Tarjeta: Acerca de ─────────────────────────────────────────────────────

  Widget _buildAcercaDeCard(ThemeData theme, ColorScheme cs) {
    return _Card(
      icon: Symbols.info,
      title: 'Acerca de',
      accentColor: cs.onSurfaceVariant,
      theme: theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Image.asset('assets/images/Logo_Inventario.png', height: 52,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Megas Inventario',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface)),
                    if (_appVersion.isNotEmpty)
                      Text('v$_appVersion',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    Text('Compilado: $kBuildDate',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: cs.outlineVariant.withAlpha(60)),
          const SizedBox(height: 14),
          _AcercaRow(icon: Symbols.business,
              label: 'Empresa', value: 'Megas Quality Services SL', cs: cs),
          const SizedBox(height: 8),
          _AcercaRow(icon: Symbols.person,
              label: 'Desarrollador',
              value: 'Catalin Andrei Sonca Dobinciuc', cs: cs),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Megas Inventario',
              applicationVersion: _appVersion.isNotEmpty ? 'v$_appVersion' : '',
              applicationLegalese:
                  '© 2025 Megas Quality Services SL\nDesarrollado por Catalin Andrei Sonca Dobinciuc',
            ),
            icon: const Icon(Symbols.gavel, size: 16),
            label: const Text('Licencias de código abierto'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Wizard de configuración inicial ────────────────────────────────────────

  Widget _buildWizard(ThemeData theme, ColorScheme cs) {
    final canEmpezar = _legacyMode
        ? (_legacyConectado && _usuarioCtrl.text.trim().isNotEmpty)
        : (_conectado && _empresaSel != null && _usuarioCtrl.text.trim().isNotEmpty);

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 48, 28, 80),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Logo
                    Image.asset('assets/images/Logo_Inventario.png',
                        height: 100,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                    const SizedBox(height: 10),
                    Text(
                      'Configuración inicial',
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _appVersion.isNotEmpty
                          ? 'v$_appVersion · $kBuildDate'
                          : kBuildDate,
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withAlpha(140)),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 36),

                    // Modo API oculto en el wizard
                    if (_showApiMode) ...[
                      _buildApiModeCard(theme, cs),
                      const SizedBox(height: 20),
                    ],

                    // Campos ERP Windows
                    if (_legacyMode) ...[
                      _buildErpCard(theme, cs),
                      if (_legacyConectado) ...[
                        const SizedBox(height: 16),
                        _buildUsuarioCard(theme, cs),
                      ],
                    ] else ...[
                      _buildConexionApiCard(theme, cs),
                      if (_conectado) ...[
                        const SizedBox(height: 16),
                        _buildEmpresaUsuarioCard(theme, cs),
                      ],
                    ],

                    const SizedBox(height: 28),

                    FilledButton.icon(
                      onPressed: canEmpezar ? _guardar : null,
                      icon: const Icon(Symbols.arrow_forward, size: 18),
                      label: const Text('Empezar'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Ruleta — acceso oculto al modo API (esquina inferior derecha)
          Positioned(
            right: 16,
            bottom: 16,
            child: IconButton(
              icon: Icon(
                Symbols.settings,
                size: 18,
                color: _showApiMode
                    ? cs.primary
                    : cs.onSurfaceVariant.withAlpha(50),
              ),
              tooltip: 'Opciones avanzadas',
              onPressed: () => setState(() => _showApiMode = !_showApiMode),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Widgets internos ──────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color accentColor;
  final ThemeData theme;
  final Widget child;
  final Widget? trailing;

  const _Card({
    required this.icon,
    required this.title,
    required this.accentColor,
    required this.theme,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Card(
      elevation: 0,
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(
                    color: accentColor.withAlpha(22),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 19, color: accentColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title.toUpperCase(),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                            letterSpacing: 0.8,
                          ),
                          overflow: TextOverflow.ellipsis),
                      if (subtitle != null)
                        Text(subtitle!.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              color: cs.onSurfaceVariant,
                              letterSpacing: 0.6,
                            )),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: cs.outlineVariant.withAlpha(60)),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _Field extends StatefulWidget {
  final TextEditingController ctrl;
  final String label;
  final String? hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;
  final Widget? trailing;

  const _Field({
    required this.ctrl,
    required this.label,
    this.hint,
    this.icon,
    this.obscure = false,
    this.keyboard,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
  });

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: widget.ctrl,
      style: TextStyle(color: cs.onSurface, fontSize: 14),
      obscureText: widget.obscure && !_visible,
      keyboardType: widget.keyboard,
      autocorrect: false,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant.withAlpha(100), fontSize: 13),
        prefixIcon: widget.icon != null ? Icon(widget.icon, size: 20) : null,
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(
                  _visible ? Symbols.visibility_off : Symbols.visibility,
                  size: 20,
                ),
                onPressed: () => setState(() => _visible = !_visible),
              )
            : widget.trailing,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _ModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer.withAlpha(100) : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: selected ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(title,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700,
                    color: selected ? cs.primary : cs.onSurface)),
            Text(subtitle,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _SesionStatus extends StatelessWidget {
  final CabecerasInventarioLocalData? sesion;
  final int lineas;
  final ThemeData theme;
  const _SesionStatus({required this.sesion, required this.lineas, required this.theme});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final has = sesion != null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: has ? cs.primaryContainer.withAlpha(80) : cs.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: has ? cs.primary.withAlpha(60) : cs.outlineVariant),
      ),
      child: has
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Symbols.pending_actions, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Text('Sesión pendiente de enviar',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600,
                          color: cs.primary, letterSpacing: 0.3)),
                ]),
                const SizedBox(height: 8),
                Text(sesion!.descripcion,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                        color: cs.onSurface),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Symbols.calendar_today, size: 12, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(_fmtDate.format(sesion!.fechaOperacion),
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                  Icon(Symbols.list_alt, size: 12, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text('$lineas líneas',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              ],
            )
          : Row(children: [
              Icon(Symbols.check_circle, size: 18, color: Colors.green.shade600),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Sin sesión pendiente',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
    );
  }
}

class _MsgBanner extends StatelessWidget {
  final String msg;
  final bool isError;
  final ThemeData theme;
  const _MsgBanner({required this.msg, required this.isError, required this.theme});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isError ? cs.errorContainer : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(
          isError ? Symbols.error_outline : Symbols.check_circle,
          size: 15,
          color: isError ? cs.onErrorContainer : Colors.green.shade700,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(msg,
              style: TextStyle(
                  fontSize: 12,
                  color: isError ? cs.onErrorContainer : Colors.green.shade800),
              overflow: TextOverflow.ellipsis, maxLines: 2),
        ),
      ]),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String msg;
  final ThemeData theme;
  const _ErrorBox({required this.msg, required this.theme});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withAlpha(80),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.error.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.error_outline, color: cs.error, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(msg,
                style: TextStyle(color: cs.onErrorContainer, fontSize: 12),
                maxLines: 4, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _BtnRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _BtnRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Text(label),
    ]);
  }
}

class _AcercaRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ColorScheme cs;
  const _AcercaRow({required this.icon, required this.label, required this.value, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(children: [
              TextSpan(text: '$label  ',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              TextSpan(text: value,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ]),
          ),
        ),
      ],
    );
  }
}

class _LoadingRow extends StatelessWidget {
  final String label;
  final Color color;
  const _LoadingRow({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      SizedBox(width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: color)),
      const SizedBox(width: 10),
      Text(label),
    ]);
  }
}

// ── Filtros de recepción ───────────────────────────────────────────────────────

class _RecibirFiltros {
  final String? proveedor;
  final String? familia;
  final Set<String> tipos; // vacío = todos
  const _RecibirFiltros({this.proveedor, this.familia, this.tipos = const {}});
}

// Tipos de artículo definidos en ARTICULO.DBF campo TIPO_ART
const _kTiposArt = [
  ('C', 'Caja'),
  ('B', 'Barril'),
  ('O', 'Otro'),
  ('V', 'Vacío'),
  ('X', 'PLVS'),
];

class _DialogFiltrosRecibir extends StatefulWidget {
  final AppDatabase db;
  final int empresaId;
  const _DialogFiltrosRecibir({required this.db, required this.empresaId});

  @override
  State<_DialogFiltrosRecibir> createState() => _DialogFiltrosRecibirState();
}

class _DialogFiltrosRecibirState extends State<_DialogFiltrosRecibir> {
  String? _proveedor;
  String? _familia;
  final Set<String> _tipos = {}; // vacío = todos

  List<String> _proveedores = [];
  List<String> _familias   = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadOpciones();
  }

  Future<void> _loadOpciones() async {
    final provs = await widget.db.getDistinctProveedores(widget.empresaId);
    final fams  = await widget.db.getDistinctFamilias(widget.empresaId);
    if (mounted) setState(() { _proveedores = provs; _familias = fams; _loading = false; });
  }

  String get _tipoLabel {
    if (_tipos.isEmpty) return 'Todos';
    // Mostrar concatenación: CB, CBO, etc.
    final orden = ['C','B','O','V','X'];
    return orden.where(_tipos.contains).join('');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Builder(builder: (ctx) {
        final kb   = MediaQuery.viewInsetsOf(ctx).bottom;
        final maxH = (MediaQuery.of(ctx).size.height - kb - 40).clamp(280.0, 700.0);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480, maxHeight: maxH),
          child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('FILTROS DE RECEPCIÓN',
                  style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700,
                    color: cs.onSurface, letterSpacing: 0.8,
                  )),
              const SizedBox(height: 4),
              Text(
                'Solo se importarán los artículos que coincidan.\nDeja en blanco para importar todos.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),

              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                // Proveedor
                DropdownButtonFormField<String?>(
                  value: _proveedor,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'PROVEEDOR',
                    prefixIcon: Icon(Symbols.business, size: 20),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Todos', style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                    ..._proveedores.map((p) => DropdownMenuItem<String?>(
                          value: p,
                          child: Text(p,
                              style: TextStyle(color: cs.onSurface),
                              overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (v) => setState(() => _proveedor = v),
                ),
                const SizedBox(height: 12),

                // Familia
                DropdownButtonFormField<String?>(
                  value: _familia,
                  style: TextStyle(color: cs.onSurface, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'FAMILIA',
                    prefixIcon: Icon(Symbols.category, size: 20),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Todos', style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                    ..._familias.map((f) => DropdownMenuItem<String?>(
                          value: f,
                          child: Text(f,
                              style: TextStyle(color: cs.onSurface),
                              overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (v) => setState(() => _familia = v),
                ),
                const SizedBox(height: 16),

                // Tipo de artículo — multi-selección con chips
                Row(
                  children: [
                    Icon(Symbols.label, size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text('TIPO DE ARTÍCULO',
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant, letterSpacing: 0.5,
                        )),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _tipos.isEmpty
                            ? cs.surfaceContainerHighest
                            : cs.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _tipoLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _tipos.isEmpty ? cs.onSurfaceVariant : cs.primary,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _kTiposArt.map((t) {
                    final selected = _tipos.contains(t.$1);
                    return FilterChip(
                      label: Text('${t.$1}  ${t.$2}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: selected ? cs.onPrimaryContainer : cs.onSurface,
                          )),
                      selected: selected,
                      onSelected: (v) => setState(() {
                        if (v) _tipos.add(t.$1);
                        else _tipos.remove(t.$1);
                      }),
                      selectedColor: cs.primaryContainer,
                      checkmarkColor: cs.primary,
                      backgroundColor: cs.surfaceContainerHighest,
                      side: BorderSide(
                        color: selected ? cs.primary : cs.outlineVariant,
                        width: selected ? 1.5 : 1,
                      ),
                    );
                  }).toList(),
                ),
                if (_tipos.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TextButton.icon(
                      onPressed: () => setState(() => _tipos.clear()),
                      icon: const Icon(Symbols.close, size: 14),
                      label: const Text('Quitar filtro de tipo'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
              ],

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _loading ? null : () => Navigator.pop(
                      context,
                      _RecibirFiltros(
                        proveedor: _proveedor,
                        familia: _familia,
                        tipos: Set.from(_tipos),
                      ),
                    ),
                    icon: const Icon(Symbols.download, size: 18),
                    label: const Text('Recibir'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      }),
    );
  }
}
