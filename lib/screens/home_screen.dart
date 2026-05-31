import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:drift/drift.dart' show Value;
import '../database/database.dart';
import '../database/tables.dart';
import '../services/config_service.dart';
import '../services/sync_service.dart';
import '../services/legacy_service.dart';
import '../services/update_service.dart';
import '../widgets/app_toast.dart';
import 'lot_editor_screen.dart';

final _fmt = NumberFormat('#,##0.00', 'es_ES');

String _sortLabel(String order) {
  switch (order) {
    case 'codigo':     return 'Código';
    case 'alfabetico': return 'A-Z';
    case 'proveedor':  return 'Proveed.';
    case 'familia':    return 'Familia';
    default:           return 'Ubicac.';
  }
}

TextStyle _tableStyle(double fontSize, String fontFamily, bool bold, TextStyle? base) {
  final w = bold ? FontWeight.w700 : FontWeight.w400;
  try {
    return GoogleFonts.getFont(fontFamily,
        textStyle: base?.copyWith(fontSize: fontSize, fontWeight: w) ??
            TextStyle(fontSize: fontSize, fontWeight: w));
  } catch (_) {
    return (base ?? const TextStyle()).copyWith(fontSize: fontSize, fontWeight: w);
  }
}

Widget _colHeaderCell(ColConfig col, TextStyle style) {
  switch (col.id) {
    case 'ubicacion':
      return SizedBox(
          width: _wUbicacion, child: Text('Ubicación', style: style));
    case 'codigo':
      return SizedBox(width: _wCodigo, child: Text('Código', style: style));
    case 'articulo':
      return Expanded(
          flex: 3,
          child: Text('Artículo',
              style: style, overflow: TextOverflow.ellipsis));
    case 'stock':
      return SizedBox(
          width: _wStock,
          child: Text('Stock', style: style, textAlign: TextAlign.right));
    case 'inventario':
      return SizedBox(
          width: _wInventario,
          child: Text('Inventario',
              style: style, textAlign: TextAlign.right));
    case 'proveedor':
      return Expanded(
          flex: 2,
          child: Text('Proveedor',
              style: style, overflow: TextOverflow.ellipsis));
    default:
      return const SizedBox.shrink();
  }
}

Widget _colDataCell(
  ColConfig col,
  ArticulosLocalData art,
  double stock,
  double conteo,
  TextStyle bodyStyle,
  ColorScheme cs,
) {
  switch (col.id) {
    case 'ubicacion':
      return SizedBox(
          width: _wUbicacion,
          child: Text(art.ubicacion ?? '',
              style: bodyStyle.copyWith(color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis));
    case 'codigo':
      return SizedBox(
          width: _wCodigo,
          child: Text(art.identificacion,
              style: bodyStyle, overflow: TextOverflow.ellipsis));
    case 'articulo':
      return Expanded(
          flex: 3,
          child: Text(art.descripcion1 ?? art.descripcion2 ?? '',
              style: bodyStyle, overflow: TextOverflow.ellipsis));
    case 'stock':
      return SizedBox(
          width: _wStock,
          child: Text(
            stock != 0 ? _fmt.format(stock) : '',
            style: bodyStyle.copyWith(
                color: stock < 0 ? cs.error : cs.onSurface),
            textAlign: TextAlign.right,
          ));
    case 'inventario':
      return SizedBox(
          width: _wInventario,
          child: Text(
            conteo != 0 ? _fmt.format(conteo) : '',
            style: bodyStyle.copyWith(
                color: cs.primary, fontWeight: FontWeight.w600),
            textAlign: TextAlign.right,
          ));
    case 'proveedor':
      return Expanded(
          flex: 2,
          child: Text(art.proveedorNombre,
              style: bodyStyle.copyWith(color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis));
    default:
      return const SizedBox.shrink();
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = AppDatabase();
  late final SyncService _sync;

  List<ArticulosLocalData> _articulos = [];
  Map<int, double> _stocks = {};
  Map<int, double> _conteos = {};
  Map<int, LineasInventarioLocalData> _lineasMap = {};
  CabecerasInventarioLocalData? _activeCabecera;
  List<AlmacenesLocalData> _almacenes = [];

  // Filtros
  List<String> _proveedores = [];
  List<String> _familias = [];
  String? _filterProveedorNombre;
  String? _filterFamiliaNombre;

  ArticulosLocalData? _selected;
  bool _loading = true;
  bool _syncing = false;
  String _search = '';
  String _sortOrder = 'ubicacion';
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  Timer? _searchDebounce;
  String _appVersion = '';


  @override
  void initState() {
    super.initState();
    _sync = SyncService(_db);
    _sortOrder = ConfigService.sortOrder;
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _appVersion = i.version);
    });
    // Comprueba actualización 5s después del arranque para no interferir con la carga
    Future.delayed(const Duration(seconds: 5), _checkForUpdate);
    if (!ConfigService.isConfigured) {
      _loadData();
      _loadFilters();
    } else if (ConfigService.isLegacyMode) {
      _doRecibir();
    } else {
      _doSync();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Widget _buildSearchField(ColorScheme cs) {
    return TextField(
      controller: _searchCtrl,
      style: TextStyle(color: cs.onSurface),
      decoration: InputDecoration(
        hintText: 'Buscar código, descripción, proveedor...',
        prefixIcon: const Icon(Symbols.search, size: 20),
        suffixIcon: _search.isNotEmpty
            ? IconButton(
                icon: const Icon(Symbols.close, size: 18),
                onPressed: () {
                  _searchDebounce?.cancel();
                  _searchCtrl.clear();
                  setState(() => _search = '');
                  _loadData();
                },
              )
            : null,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
      ),
      onChanged: (v) {
        setState(() => _search = v);
        _searchDebounce?.cancel();
        _searchDebounce = Timer(const Duration(milliseconds: 300), _loadData);
      },
    );
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    AppToast.show(context, msg, error: error);
  }

  Future<void> _loadFilters() async {
    final eid = ConfigService.isLegacyMode ? 0 : ConfigService.empresaId;
    if (!ConfigService.isLegacyMode && eid <= 0) return;
    final provs = await _db.getDistinctProveedores(eid);
    final fams = await _db.getDistinctFamilias(eid);
    if (mounted) {
      setState(() {
        _proveedores = provs;
        _familias = fams;
      });
    }
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final eid = ConfigService.empresaId;

      // Almacenes y cabeceras en paralelo — no dependen entre sí
      final almacenesFut = _db.getAlmacenes(eid);
      final cabecerasFut = _db.getCabeceras(eid);
      final almacenes = await almacenesFut;
      final cabs      = await cabecerasFut;

      // Sesión activa: la más reciente NO sincronizada
      CabecerasInventarioLocalData? cab;
      if (cabs.isNotEmpty) {
        final unsync = cabs.where((c) => !c.sincronizado);
        cab = unsync.isNotEmpty ? unsync.first : null;
      }

      List<ArticulosLocalData> arts = [];
      Map<int, double> stk = {};
      final Map<int, double> cnt = {};
      final Map<int, LineasInventarioLocalData> lineasMap = {};

      // Solo cargar artículos cuando hay sesión activa (F8)
      if (cab != null) {
        // Artículos, stock y líneas en paralelo — solo dependen de cab.id/eid
        final artsFut   = _db.getArticulos(
          eid,
          search: _search.isEmpty ? null : _search,
          proveedorNombre: _filterProveedorNombre,
          familiaNombre: _filterFamiliaNombre,
          sortOrder: _sortOrder,
        );
        final stkFut    = _db.getStockTotalPorArticulo(eid);
        final lineasFut = _db.getLineas(cab.id);

        arts            = await artsFut;
        stk             = await stkFut;
        final lineas    = await lineasFut;

        for (final l in lineas) {
          cnt[l.articuloId] = (cnt[l.articuloId] ?? 0) + l.stock;
          lineasMap.putIfAbsent(l.articuloId, () => l);
        }
      }

      if (mounted) {
        setState(() {
          _articulos      = arts;
          _stocks         = stk;
          _conteos        = cnt;
          _almacenes      = almacenes;
          _activeCabecera = cab;
          _lineasMap      = lineasMap;
          _loading        = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showSnack('Error cargando datos: $e', error: true);
      }
    }
  }

  // ── Sesión ────────────────────────────────────────────────────────────────

  Future<CabecerasInventarioLocalData?> _ensureCabecera() async {
    if (_activeCabecera != null) return _activeCabecera;

    if (_almacenes.isEmpty) {
      _showSnack('Sincroniza primero para cargar los almacenes');
      return null;
    }

    int almacenId;
    DateTime fecha;
    String descripcion;

    if (ConfigService.isLegacyMode) {
      // En legacy el almacén ya está configurado — no pedir al usuario
      almacenId = int.tryParse(ConfigService.legacyAlmacen) ?? 1;
      fecha = DateTime.now();
      descripcion = 'Inventario Almacén $almacenId';
    } else {
      final params = await showDialog<_SesionParams>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DialogSesion(almacenes: _almacenes),
      );
      if (params == null || !mounted) return null;
      almacenId   = params.almacenId;
      fecha       = params.fecha;
      descripcion = params.descripcion;
    }

    await _db.insertCabecera(CabecerasInventarioLocalCompanion(
      empresaId: Value(ConfigService.empresaId),
      almacenId: Value(almacenId),
      fechaOperacion: Value(fecha),
      descripcion: Value(descripcion),
      fechaCreacion: Value(DateTime.now()),
    ));
    await _loadData();
    return _activeCabecera;
  }

  // ── Acciones ──────────────────────────────────────────────────────────────

  Future<void> _doSync() async {
    setState(() => _syncing = true);
    try {
      final result = await _sync.syncAll();
      if (mounted) {
        _showSnack(
            'Sincronizado: ${result.articulos} artículos, ${result.almacenes} almacenes');
        await _loadData();
        await _loadFilters();
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Error de sincronización: $e', error: true);
        await _loadData();
        await _loadFilters();
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _checkForUpdate() async {
    if (!mounted) return;
    final update = await UpdateService.checkForUpdate();
    if (update == null || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(update: update),
    );
  }

  Future<void> _doRecibir() async {
    setState(() => _syncing = true);
    try {
      final legacy = LegacyService(_db);
      final result = await legacy.recibir();
      if (mounted) {
        _showSnack('Recibido: ${result.articulos} artículos, ${result.lotes} lotes');
        await _loadData();
        await _loadFilters();
      }
    } catch (e) {
      if (mounted) {
        _showSnack('Error al conectar con el servidor: $e', error: true);
        await _loadData();
        await _loadFilters();
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _openLotEditor(ArticulosLocalData art) async {
    setState(() => _selected = art);
    final cab = await _ensureCabecera();
    if (cab == null || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LotEditorScreen(articulo: art, cabecera: cab),
      ),
    );
    if (mounted) await _loadData();
  }

  Future<void> _doNuevaCantidad() async {
    if (_selected == null) {
      _showSnack('Selecciona un artículo de la lista');
      return;
    }
    await _openLotEditor(_selected!);
  }

  Future<void> _doEditar() async {
    if (_selected == null) return;
    await _openLotEditor(_selected!);
  }

  Future<void> _doEliminar() async {
    final art = _selected;
    if (art == null) return;
    final linea = _lineasMap[art.articuloId];
    if (linea == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar conteo'),
        content: Text(
            '¿Eliminar el conteo de «${art.descripcion1 ?? art.identificacion}»?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _db.deleteLinea(linea.id);
    await _loadData();
  }

  Future<void> _doModificarArticulo() async {
    final art = _selected;
    if (art == null) return;
    final result = await showDialog<ArticuloEditResult>(
      context: context,
      builder: (_) => ArticuloEditDialog(articulo: art),
    );
    if (result == null || !mounted) return;
    await _db.updateArticuloFields(
      ConfigService.isLegacyMode ? 0 : ConfigService.empresaId,
      art.articuloId,
      cbarra: result.cbarra,
      peso:   result.peso,
      unicaj: result.unicaj,
      unipal: result.unipal,
    );
    if (ConfigService.isLegacyMode) {
      try {
        final svc = LegacyService(_db);
        await svc.saveArticuloFields(
          art.identificacion,
          cbarra: result.cbarra,
          peso:   result.peso,
          unicaj: result.unicaj,
          unipal: result.unipal,
        );
        if (mounted) _showSnack('Artículo guardado');
      } catch (e) {
        if (mounted) _showSnack('Error DBF: $e', error: true);
      }
    }
    if (mounted) await _loadData();
  }

  Future<void> _doSalir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Salir'),
        content: const Text('¿Cerrar la aplicación?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    if (ok == true) SystemNavigator.pop();
  }

  void _scrollToSelected() {
    if (!_scrollCtrl.hasClients || _selected == null) return;
    final idx = _articulos
        .indexWhere((a) => a.articuloId == _selected!.articuloId);
    if (idx < 0) return;
    final itemTop = idx * 40.0;
    final itemBottom = itemTop + 40.0;
    final viewH = _scrollCtrl.position.viewportDimension;
    final offset = _scrollCtrl.offset;
    if (itemTop < offset) {
      _scrollCtrl.jumpTo(itemTop);
    } else if (itemBottom > offset + viewH) {
      _scrollCtrl.jumpTo(itemBottom - viewH);
    }
  }

  void _scrollUp() {
    if (_articulos.isEmpty) return;
    final idx = _selected == null
        ? 0
        : _articulos
            .indexWhere((a) => a.articuloId == _selected!.articuloId);
    final newIdx = (idx - 1).clamp(0, _articulos.length - 1);
    if (newIdx == idx && _selected != null) return;
    setState(() => _selected = _articulos[newIdx]);
    _scrollToSelected();
  }

  void _scrollDown() {
    if (_articulos.isEmpty) return;
    final idx = _selected == null
        ? -1
        : _articulos
            .indexWhere((a) => a.articuloId == _selected!.articuloId);
    final newIdx = (idx + 1).clamp(0, _articulos.length - 1);
    if (newIdx == idx && _selected != null) return;
    setState(() => _selected = _articulos[newIdx]);
    _scrollToSelected();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    // Calculados UNA vez por build del padre — evita GoogleFonts + jsonDecode por fila
    final rowStyle = _tableStyle(
      ConfigService.tableFontSize,
      ConfigService.tableFont,
      ConfigService.tableFontBold,
      theme.textTheme.bodySmall?.copyWith(color: cs.onSurface),
    );
    final visibleCols = ConfigService.tableColumns.where((c) => c.visible).toList();
    final selStock =
        _selected != null ? (_stocks[_selected!.articuloId] ?? 0.0) : 0.0;
    final selConteo =
        _selected != null ? (_conteos[_selected!.articuloId] ?? 0.0) : 0.0;
    final hasLinea = _selected != null &&
        _lineasMap.containsKey(_selected!.articuloId);

    final hasFilters =
        _proveedores.isNotEmpty || _familias.isNotEmpty;
    final filterActive =
        _filterProveedorNombre != null || _filterFamiliaNombre != null;

    return Scaffold(
      appBar: AppBar(
        foregroundColor: cs.onSurface,
        title: Row(
          children: [
            Image.asset('assets/images/logo.png', height: 32,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ConfigService.isLegacyMode
                        ? (ConfigService.legacyEmpresaNombre.isNotEmpty
                            ? ConfigService.legacyEmpresaNombre
                            : 'Almacén ${ConfigService.legacyAlmacen}')
                        : (ConfigService.empresaNombre.isNotEmpty
                            ? ConfigService.empresaNombre
                            : 'Inventario'),
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  if (_activeCabecera != null)
                    Text(
                      '${_activeCabecera!.descripcion} · '
                      '${DateFormat('dd/MM').format(_activeCabecera!.fechaOperacion)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),
        // En landscape la búsqueda va dentro del body (solo sobre la lista)
        bottom: isLandscape ? null : PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: _buildSearchField(cs),
          ),
        ),
        actions: [
          if (ConfigService.usuario.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.person, size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      ConfigService.usuario,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: Column(
        children: [
          // Barra de progreso global (E2)
          if (_loading)
            const LinearProgressIndicator()
          else
            const SizedBox(height: 2),

          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Columna tabla
                Expanded(
                  child: Column(
                    children: [
                      // Búsqueda inline en landscape (no va en AppBar)
                      if (isLandscape)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                          child: _buildSearchField(cs),
                        ),
                      // Barra de filtros (F7)
                      if (hasFilters && _activeCabecera != null)
                        _FilterBar(
                          proveedores: _proveedores,
                          familias: _familias,
                          proveedorNombre: _filterProveedorNombre,
                          familiaNombre: _filterFamiliaNombre,
                          filterActive: filterActive,
                          onProveedorChanged: (v) {
                            setState(() => _filterProveedorNombre = v);
                            _loadData();
                          },
                          onFamiliaChanged: (v) {
                            setState(() => _filterFamiliaNombre = v);
                            _loadData();
                          },
                          onClearFilters: () {
                            setState(() {
                              _filterProveedorNombre = null;
                              _filterFamiliaNombre = null;
                            });
                            _loadData();
                          },
                        ),
                      _TableHeader(theme: theme),
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: cs.outlineVariant),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _activeCabecera == null && !_loading
                              ? _NoSesionState(
                                  key: const ValueKey('no-sesion'),
                                  theme: theme,
                                  onCrear: _ensureCabecera,
                                )
                              : _articulos.isEmpty && !_loading
                                  ? _EmptyState(
                                      key: const ValueKey('empty'),
                                      theme: theme,
                                    )
                                  : Scrollbar(
                                      controller: _scrollCtrl,
                                      thumbVisibility: true,
                                      child: ListView.builder(
                                      key: const ValueKey('list'),
                                      controller: _scrollCtrl,
                                      padding: EdgeInsets.zero,
                                      itemCount: _articulos.length,
                                      itemExtent: 40,
                                      itemBuilder: (ctx, i) {
                                        final art = _articulos[i];
                                        return RepaintBoundary(
                                          child: _ArticuloRow(
                                            articulo: art,
                                            stock: _stocks[art.articuloId] ?? 0,
                                            conteo: _conteos[art.articuloId] ?? 0,
                                            selected: _selected?.articuloId == art.articuloId,
                                            counted: _lineasMap.containsKey(art.articuloId),
                                            index: i,
                                            onTap: () {
                                              if (_selected?.articuloId != art.articuloId) {
                                                setState(() => _selected = art);
                                              }
                                            },
                                            onLongPress: () => _openLotEditor(art),
                                            theme: theme,
                                            bodyStyle: rowStyle,
                                            visibleCols: visibleCols,
                                          ),
                                        );
                                      },
                                    )),
                        ),
                      ),
                    ],
                  ),
                ),

                // Panel de acciones (derecha)
                _ActionPanel(
                  selected: _selected,
                  syncing: _syncing,
                  hasLinea: hasLinea,
                  sortOrder: _sortOrder,
                  isLegacy: ConfigService.isLegacyMode,
                  onSync: _doSync,
                  onConfig: () async {
                    await context.push('/config');
                    if (mounted) {
                      await _loadData();
                      await _loadFilters();
                    }
                  },
                  onNuevaCantidad: _doNuevaCantidad,
                  onEditar: _doEditar,
                  onEliminar: _doEliminar,
                  onModificarArticulo: _doModificarArticulo,
                  onScrollUp: _scrollUp,
                  onScrollDown: _scrollDown,
                  onSortChanged: (v) async {
                    setState(() => _sortOrder = v);
                    await ConfigService.saveSortOrder(v);
                    _loadData();
                  },
                  onSalir: _doSalir,
                  isLandscape: isLandscape,
                ),

              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant),
          _BottomInfoPanel(
            selected: _selected,
            stock: selStock,
            conteo: selConteo,
            totalContados: _lineasMap.length,
            activeCabecera: _activeCabecera,
            almacenes: _almacenes,
            appVersion: _appVersion,
            theme: theme,
            isLandscape: isLandscape,
            onConfig: () async {
              await context.push('/config');
              if (mounted) { await _loadData(); await _loadFilters(); }
            },
            onSalir: _doSalir,
          ),
        ],
      ),
    );
  }
}

// ── Anchos de columna compartidos ────────────────────────────────────────────

const _wUbicacion = 80.0;
const _wCodigo = 110.0;
const _wStock = 115.0;
const _wInventario = 115.0;
const _colGap = 6.0;

// ── Panel de acciones ──────────────────────────────────────────────────────────

class _ActionPanel extends StatelessWidget {
  final ArticulosLocalData? selected;
  final bool syncing;
  final bool hasLinea;
  final String sortOrder;
  final bool isLegacy;
  final VoidCallback onSync;
  final VoidCallback onConfig;
  final VoidCallback onNuevaCantidad;
  final VoidCallback onEditar;
  final VoidCallback onEliminar;
  final VoidCallback onModificarArticulo;
  final VoidCallback onScrollUp;
  final VoidCallback onScrollDown;
  final void Function(String) onSortChanged;
  final VoidCallback onSalir;
  final bool isLandscape;

  const _ActionPanel({
    required this.selected,
    required this.syncing,
    required this.hasLinea,
    required this.sortOrder,
    required this.isLegacy,
    required this.onSync,
    required this.onConfig,
    required this.onNuevaCantidad,
    required this.onEditar,
    required this.onEliminar,
    required this.onModificarArticulo,
    required this.onScrollUp,
    required this.onScrollDown,
    required this.onSortChanged,
    required this.onSalir,
    this.isLandscape = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasSelection = selected != null;

    return Container(
      width: 120,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(left: BorderSide(color: cs.outlineVariant)),
      ),
      // Distribución flex: cada botón acción flex=1, Subir/Bajar flex=2 cada uno
      // Sin scroll, todos siempre visibles. Flutter distribuye el espacio.
      child: Column(
        children: [
          // ── Nueva cantidad ─────────────────────────────────────────────
          Expanded(
            flex: 1,
            child: _ActionBtn(
              icon: Symbols.add_circle,
              label: isLandscape ? '' : 'Nueva\ncantidad',
              enabled: hasSelection,
              color: cs.primary,
              onTap: onNuevaCantidad,
              fillHeight: true,
              iconSize: 26,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          // ── Editar ─────────────────────────────────────────────────────
          Expanded(
            flex: 1,
            child: _ActionBtn(
              icon: Symbols.edit,
              label: isLandscape ? '' : 'Editar',
              enabled: hasLinea,
              onTap: onEditar,
              fillHeight: true,
              iconSize: 24,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          // ── Eliminar ───────────────────────────────────────────────────
          Expanded(
            flex: 1,
            child: _ActionBtn(
              icon: Symbols.delete,
              label: isLandscape ? '' : 'Eliminar',
              enabled: hasLinea,
              danger: true,
              onTap: onEliminar,
              fillHeight: true,
              iconSize: 24,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          // ── Modificar artículo (legacy) ────────────────────────────────
          if (isLegacy) ...[
            Expanded(
              flex: 1,
              child: _ActionBtn(
                icon: Symbols.tune,
                label: isLandscape ? '' : 'Modificar',
                enabled: hasSelection,
                onTap: onModificarArticulo,
                fillHeight: true,
                iconSize: 24,
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant),
          ],
          // ── Ordenar/Filtro ─────────────────────────────────────────────
          Expanded(
            flex: 1,
            child: PopupMenuButton<String>(
              tooltip: 'Ordenar',
              initialValue: sortOrder,
              onSelected: onSortChanged,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'ubicacion',  child: Text('Ubicación')),
                PopupMenuItem(value: 'codigo',     child: Text('Código')),
                PopupMenuItem(value: 'alfabetico', child: Text('Alfabético')),
                PopupMenuItem(value: 'proveedor',  child: Text('Proveedor')),
                PopupMenuItem(value: 'familia',    child: Text('Familia')),
              ],
              child: SizedBox.expand(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Symbols.sort, size: 22, color: cs.primary),
                    const SizedBox(height: 2),
                    Text(_sortLabel(sortOrder),
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: cs.primary),
                        textAlign: TextAlign.center),
                    Icon(Symbols.arrow_drop_down, size: 12, color: cs.primary),
                  ],
                ),
              ),
            ),
          ),
          // ── Subir / Bajar — flex 2 cada uno (2x más grandes) ──────────
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            flex: 2,
            child: _ActionBtn(
              icon: Symbols.keyboard_arrow_up,
              label: 'Subir ▲',
              onTap: onScrollUp,
              fillHeight: true,
              iconSize: 32,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            flex: 2,
            child: _ActionBtn(
              icon: Symbols.keyboard_arrow_down,
              label: 'Bajar ▼',
              onTap: onScrollDown,
              fillHeight: true,
              iconSize: 32,
            ),
          ),
          // ── Config + Salir — portrait solamente ────────────────────────
          if (!isLandscape) ...[
            Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            _ActionBtn(icon: Symbols.settings, label: 'Config.', onTap: onConfig, height: 48),
            _ActionBtn(icon: Symbols.logout, label: 'Salir', danger: true, onTap: onSalir, height: 48),
          ],
        ],
      ),
    );
  }
}

class _ActionBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool danger;
  final Color? color;
  final double height;
  final double iconSize;
  final bool fillHeight;

  const _ActionBtn({
    required this.icon,
    required this.label,
    this.onTap,
    this.enabled = true,
    this.danger = false,
    this.color,
    this.height = 60,
    this.iconSize = 26,
    this.fillHeight = false,
  });

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = widget.enabled && widget.onTap != null;
    final accent = widget.danger ? cs.error : (widget.color ?? cs.primary);
    final iconColor = !active
        ? cs.onSurface.withAlpha(60)
        : widget.danger
            ? cs.error
            : widget.color ?? cs.onSurfaceVariant;

    return GestureDetector(
      onTapDown: active ? (_) => setState(() => _pressed = true) : null,
      onTapUp: active
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        height: widget.fillHeight ? double.infinity : widget.height,
        width: double.infinity,
        color: _pressed ? accent.withAlpha(55) : Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, color: iconColor, size: widget.iconSize),
            if (widget.label.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 10,
                color: iconColor,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
            ),
            ], // end if label.isNotEmpty
          ],
        ),
      ),
    );
  }
}

// ── Barra de filtros ──────────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  final List<String> proveedores;
  final List<String> familias;
  final String? proveedorNombre;
  final String? familiaNombre;
  final bool filterActive;
  final ValueChanged<String?> onProveedorChanged;
  final ValueChanged<String?> onFamiliaChanged;
  final VoidCallback onClearFilters;

  const _FilterBar({
    required this.proveedores,
    required this.familias,
    required this.proveedorNombre,
    required this.familiaNombre,
    required this.filterActive,
    required this.onProveedorChanged,
    required this.onFamiliaChanged,
    required this.onClearFilters,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final landscape = MediaQuery.of(context).orientation == Orientation.landscape;
    return Container(
      height: landscape ? 36 : 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: cs.surfaceContainerLow,
      child: Row(
        children: [
          if (proveedores.isNotEmpty) ...[
            Text('Proveedor:',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(width: 4),
            Expanded(
              child: _FilterDropdown(
                hint: 'Todos',
                value: proveedorNombre,
                items: proveedores,
                onChanged: onProveedorChanged,
              ),
            ),
          ],
          if (proveedores.isNotEmpty && familias.isNotEmpty)
            const SizedBox(width: 12),
          if (familias.isNotEmpty) ...[
            Text('Familia:',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(width: 4),
            Expanded(
              child: _FilterDropdown(
                hint: 'Todas',
                value: familiaNombre,
                items: familias,
                onChanged: onFamiliaChanged,
              ),
            ),
          ],
          if (filterActive)
            IconButton(
              icon: Icon(Symbols.filter_alt_off,
                  size: 18, color: cs.primary),
              tooltip: 'Quitar filtros',
              onPressed: onClearFilters,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  final String hint;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  const _FilterDropdown({
    required this.hint,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: value,
        hint: Text(hint,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        isExpanded: true,
        isDense: true,
        style: TextStyle(fontSize: 12, color: cs.onSurface),
        dropdownColor: cs.surface,
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(hint,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          ...items.map((nombre) => DropdownMenuItem<String?>(
                value: nombre,
                child: Text(nombre,
                    style: TextStyle(fontSize: 12, color: cs.onSurface),
                    overflow: TextOverflow.ellipsis),
              )),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

// ── Cabecera de la tabla ──────────────────────────────────────────────────────

class _TableHeader extends StatelessWidget {
  final ThemeData theme;
  const _TableHeader({required this.theme});

  @override
  Widget build(BuildContext context) {
    final fs = ConfigService.tableFontSize - 1;
    final style = _tableStyle(
      fs,
      ConfigService.tableFont,
      true, // cabecera siempre bold
      theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.4,
      ),
    );
    final cols =
        ConfigService.tableColumns.where((c) => c.visible).toList();
    return Container(
      height: 34,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (int i = 0; i < cols.length; i++) ...[
            if (i > 0) const SizedBox(width: _colGap),
            _colHeaderCell(cols[i], style),
          ],
        ],
      ),
    );
  }
}

// ── Fila de artículo ──────────────────────────────────────────────────────────

class _ArticuloRow extends StatefulWidget {
  final ArticulosLocalData articulo;
  final double stock;
  final double conteo;
  final bool selected;
  final bool counted;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ThemeData theme;
  // Pre-computados en el padre para evitar GoogleFonts + jsonDecode por fila
  final TextStyle bodyStyle;
  final List<ColConfig> visibleCols;

  const _ArticuloRow({
    required this.articulo,
    required this.stock,
    required this.conteo,
    required this.selected,
    required this.counted,
    required this.index,
    required this.onTap,
    required this.onLongPress,
    required this.theme,
    required this.bodyStyle,
    required this.visibleCols,
  });

  @override
  State<_ArticuloRow> createState() => _ArticuloRowState();
}

class _ArticuloRowState extends State<_ArticuloRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = widget.theme.colorScheme;

    Color rowColor;
    if (widget.selected) {
      rowColor = cs.primary.withAlpha(40);
    } else if (widget.counted) {
      rowColor = Colors.green.withAlpha(50);
    } else if (widget.stock < 0) {
      rowColor = Colors.red.withAlpha(35);
    } else if (widget.stock == 0) {
      rowColor = Colors.amber.withAlpha(35);
    } else if (widget.index.isOdd) {
      rowColor = cs.surfaceContainerLow;
    } else {
      rowColor = Colors.transparent;
    }

    return GestureDetector(
      onTapDown: (_) {
        setState(() => _pressed = true);
        widget.onTap();
      },
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: widget.onLongPress,
      child: Container(
        height: 40,
        color: _pressed ? cs.primary.withAlpha(60) : rowColor,
        child: Row(
          children: [
            // Barra lateral de selección — muy visible
            AnimatedContainer(
              duration: const Duration(milliseconds: 50),
              width: widget.selected ? 4 : 0,
              height: 40,
              color: cs.primary,
            ),
            // Contenido de la fila
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    for (int i = 0; i < widget.visibleCols.length; i++) ...[
                      if (i > 0) const SizedBox(width: _colGap),
                      _colDataCell(widget.visibleCols[i], widget.articulo,
                          widget.stock, widget.conteo, widget.bodyStyle, cs),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Panel inferior ────────────────────────────────────────────────────────────

class _BottomInfoPanel extends StatelessWidget {
  final ArticulosLocalData? selected;
  final double stock;
  final double conteo;
  final int totalContados;
  final CabecerasInventarioLocalData? activeCabecera;
  final List<AlmacenesLocalData> almacenes;
  final String appVersion;
  final ThemeData theme;
  final bool isLandscape;
  final VoidCallback? onConfig;
  final VoidCallback? onSalir;

  const _BottomInfoPanel({
    required this.selected,
    required this.stock,
    required this.conteo,
    required this.totalContados,
    required this.activeCabecera,
    required this.almacenes,
    required this.appVersion,
    required this.theme,
    this.isLandscape = false,
    this.onConfig,
    this.onSalir,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final lbl = theme.textTheme.bodySmall
        ?.copyWith(color: cs.onSurfaceVariant);
    final val = theme.textTheme.bodySmall
        ?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface);

    String almacenNombre = '';
    if (activeCabecera != null) {
      final match = almacenes
          .where((a) => a.almacenId == activeCabecera!.almacenId);
      almacenNombre = match.isNotEmpty ? match.first.nombre : '';
    }

    final diff = conteo - stock;
    final diffColor = diff == 0
        ? cs.onSurface
        : diff > 0
            ? Colors.green.shade700
            : cs.error;
    final diffVal =
        val?.copyWith(color: diffColor, fontWeight: FontWeight.w700);

    return Container(
      constraints: const BoxConstraints(minHeight: 72, maxHeight: 120),
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Stack(
        children: [
          Positioned(
            right: 0,
            bottom: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // En landscape: Config + Salir compactos aquí
                if (isLandscape) Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onConfig != null)
                      GestureDetector(
                        onTap: onConfig,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Symbols.settings, size: 13, color: cs.onSurfaceVariant.withAlpha(180)),
                            const SizedBox(width: 2),
                            Text('Config', style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant.withAlpha(180))),
                          ]),
                        ),
                      ),
                    if (onSalir != null)
                      GestureDetector(
                        onTap: onSalir,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Symbols.logout, size: 13, color: cs.error.withAlpha(180)),
                            const SizedBox(width: 2),
                            Text('Salir', style: TextStyle(fontSize: 9, color: cs.error.withAlpha(180))),
                          ]),
                        ),
                      ),
                  ],
                ),
                if (appVersion.isNotEmpty)
                  Text('v$appVersion',
                    style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant.withAlpha(100))),
              ],
            ),
          ),
        Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _InfoLine('Almacén:', almacenNombre, lbl, val),
                _InfoLine(
                    'Código:', selected?.identificacion ?? '', lbl, val),
                _InfoLine(
                    'Proveedor:', selected?.proveedorNombre ?? '', lbl, val),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _InfoLine(
                    'Familia:', selected?.familiaNombre ?? '', lbl, val),
                _InfoLine(
                    'Stock:',
                    selected != null ? _fmt.format(stock) : '',
                    lbl,
                    val),
                _InfoLine(
                    'Inventario:',
                    selected != null ? _fmt.format(conteo) : '',
                    lbl,
                    val),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _InfoLine('Contados:', '$totalContados art.', lbl, val),
                if (activeCabecera != null)
                  _InfoLine(
                      'Sesión:', activeCabecera!.descripcion, lbl, val),
                if (selected != null)
                  _InfoLine(
                    'Diferencia:',
                    (diff >= 0 ? '+' : '') + _fmt.format(diff),
                    lbl,
                    diffVal,
                  ),
              ],
            ),
          ),
        ],
      ), // Row
        ],
      ), // Stack
    );
  }
}

// ── Diálogo de actualización ──────────────────────────────────────────────────

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo update;
  const _UpdateDialog({required this.update});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _descargando = false;
  bool _error = false;
  double _progress = 0;

  Future<void> _descargar() async {
    setState(() { _descargando = true; _error = false; });
    try {
      await UpdateService.downloadAndInstall(
        widget.update.url,
        onProgress: (p) { if (mounted) setState(() => _progress = p); },
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() { _descargando = false; _error = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = (_progress * 100).toInt();

    return AlertDialog(
      title: Row(children: [
        Icon(Icons.system_update_rounded, color: cs.primary, size: 22),
        const SizedBox(width: 10),
        const Text('Nueva versión disponible'),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Versión ${widget.update.version}',
              style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary)),
          if (widget.update.notas.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(widget.update.notas,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ],
          if (_descargando) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 6),
            Text(
              _progress > 0 ? 'Descargando… $pct%' : 'Conectando…',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
          if (_error) ...[
            const SizedBox(height: 10),
            Text('Error al descargar. Comprueba la conexión.',
                style: TextStyle(fontSize: 12, color: cs.error)),
          ],
        ],
      ),
      actions: _descargando
          ? null
          : [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Ahora no'),
              ),
              FilledButton.icon(
                onPressed: _descargar,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Actualizar'),
              ),
            ],
    );
  }
}

Widget _InfoLine(
    String lbl, String val, TextStyle? lblStyle, TextStyle? valStyle) {
  return RichText(
    overflow: TextOverflow.ellipsis,
    text: TextSpan(children: [
      TextSpan(text: '$lbl ', style: lblStyle),
      TextSpan(text: val, style: valStyle),
    ]),
  );
}

// ── Estado sin sesión (F8) ────────────────────────────────────────────────────

class _NoSesionState extends StatelessWidget {
  final ThemeData theme;
  final Future<CabecerasInventarioLocalData?> Function() onCrear;

  const _NoSesionState({
    super.key,
    required this.theme,
    required this.onCrear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.inventory_2,
              size: 72, color: cs.outlineVariant),
          const SizedBox(height: 16),
          Text('Sin sesión de inventario activa',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: cs.onSurface)),
          const SizedBox(height: 8),
          Text(
            'Crea una nueva sesión para comenzar a contar artículos.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCrear,
            icon: const Icon(Symbols.add),
            label: const Text('Nueva sesión'),
          ),
        ],
      ),
    );
  }
}

// ── Estado vacío ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final ThemeData theme;
  const _EmptyState({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.search_off,
              size: 72, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Text('Sin artículos',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.onSurface)),
          const SizedBox(height: 8),
          Text(
            'Ajusta los filtros o el texto de búsqueda.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Diálogo de sesión ─────────────────────────────────────────────────────────

class _SesionParams {
  final int almacenId;
  final DateTime fecha;
  final String descripcion;
  const _SesionParams(this.almacenId, this.fecha, this.descripcion);
}

class _DialogSesion extends StatefulWidget {
  final List<AlmacenesLocalData> almacenes;
  const _DialogSesion({required this.almacenes});

  @override
  State<_DialogSesion> createState() => _DialogSesionState();
}

class _DialogSesionState extends State<_DialogSesion> {
  late int _almacenId;
  late DateTime _fecha;
  late TextEditingController _descCtrl;

  @override
  void initState() {
    super.initState();
    _almacenId = widget.almacenes.first.almacenId;
    _fecha = DateTime.now();
    _descCtrl = TextEditingController(text: _buildDesc(_fecha));
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  String _buildDesc(DateTime d) {
    final fmt = DateFormat('dd/MM/yyyy HH:mm');
    final u = ConfigService.usuario;
    return u.isNotEmpty
        ? 'Inventario ${fmt.format(d)} · $u'
        : 'Inventario ${fmt.format(d)}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(2020),
      lastDate: DateTime(2099),
    );
    if (picked != null && mounted) {
      setState(() {
        _fecha = DateTime(
          picked.year,
          picked.month,
          picked.day,
          DateTime.now().hour,
          DateTime.now().minute,
        );
        _descCtrl.text = _buildDesc(_fecha);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(minWidth: 480, maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nueva sesión de inventario',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<int>(
                value: _almacenId,
                style: TextStyle(color: cs.onSurface),
                decoration: const InputDecoration(
                  labelText: 'Almacén',
                  prefixIcon: Icon(Symbols.warehouse),
                ),
                items: widget.almacenes
                    .map((a) => DropdownMenuItem(
                          value: a.almacenId,
                          child: Text(a.nombre,
                              style: TextStyle(color: cs.onSurface)),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _almacenId = v ?? _almacenId),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Symbols.calendar_month, size: 18),
                label: Text(
                    'Fecha: ${DateFormat('dd/MM/yyyy').format(_fecha)}'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descCtrl,
                style: TextStyle(color: cs.onSurface),
                decoration: const InputDecoration(
                  labelText: 'Nombre de sesión',
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancelar')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _SesionParams(
                        _almacenId,
                        _fecha,
                        _descCtrl.text.trim().isNotEmpty
                            ? _descCtrl.text.trim()
                            : _buildDesc(_fecha),
                      ),
                    ),
                    child: const Text('Crear'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
