import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../database/database.dart';
import '../services/config_service.dart';
import '../services/legacy_service.dart';
import '../services/log_service.dart';
import '../widgets/app_toast.dart';

const _kAdminPassword = 'Megas_1024';

/// Pide la contraseña de administración. true = correcta.
Future<bool> _pedirPassword(BuildContext context) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Contraseña requerida'),
      content: TextField(
        controller: ctrl,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Contraseña'),
        onSubmitted: (_) => Navigator.pop(ctx, ctrl.text == _kAdminPassword),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text == _kAdminPassword),
          child: const Text('Aceptar'),
        ),
      ],
    ),
  );
  if (ok == false && context.mounted) {
    AppToast.show(context, 'Contraseña incorrecta', error: true);
  }
  return ok == true;
}

final _fmtTs = DateFormat('dd/MM HH:mm:ss');
final _fmtDia = DateFormat('dd/MM/yyyy');
final _fmtDiaHora = DateFormat('dd/MM/yyyy HH:mm');

String _fmtCant(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3);

typedef _Inventario = ({
  CabecerasInventarioLocalData cab,
  List<LineasInventarioLocalData> lineas,
});

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  // 'incidencias' | 'auditoria' | 'inventarios'
  String _vista = 'incidencias';

  final _db = AppDatabase();
  List<LogEntry> _incidencias = [];
  List<LogEntry> _auditoria = [];
  List<_Inventario> _inventarios = [];
  bool _soloErrores = false;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final results = await Future.wait([
      LogService.obtenerRegistros(),
      LogService.obtenerAuditoria(),
    ]);
    final eid = ConfigService.isLegacyMode ? 0 : ConfigService.empresaId;
    final cabs = await _db.getCabeceras(eid);
    cabs.sort((a, b) => b.fechaCreacion.compareTo(a.fechaCreacion));
    final inventarios = <_Inventario>[];
    for (final c in cabs) {
      inventarios.add((cab: c, lineas: await _db.getLineas(c.id)));
    }
    if (mounted) {
      setState(() {
        _incidencias = results[0];
        _auditoria = results[1];
        _inventarios = inventarios;
        _cargando = false;
      });
    }
  }

  List<LogEntry> get _incidenciasFiltradas =>
      _soloErrores ? _incidencias.where((e) => e.isError).toList() : _incidencias;

  List<LogEntry> get _entradas =>
      _vista == 'auditoria' ? _auditoria : _incidenciasFiltradas;

  Future<void> _copiarTodo() async {
    final String texto;
    if (_vista == 'inventarios') {
      texto = _inventarios.map((inv) {
        final cab = inv.cab;
        final estado = cab.sincronizado ? 'ENVIADO' : 'PENDIENTE';
        final cabTxt = 'INVENTARIO ${_fmtDia.format(cab.fechaOperacion)} '
            'alm ${cab.almacenId} [$estado] ${cab.descripcion}';
        final lineasTxt = inv.lineas.map((l) {
          final lote = (l.codigoLote ?? '').isEmpty || l.codigoLote == 'SIN_LOTE'
              ? ''
              : ' lote ${l.codigoLote}';
          return '  ${l.articuloCodigo} ${l.articuloDescripcion}$lote: '
              '${_fmtCant(l.stock)}';
        }).join('\n');
        return '$cabTxt\n$lineasTxt';
      }).join('\n\n');
    } else {
      texto = _entradas.map((e) {
        final prefijo = e.isAudit ? '📋' : e.isError ? '❌' : '✓';
        return '$prefijo [${_fmtTs.format(e.timestamp)}] ${e.mensaje}';
      }).join('\n');
    }
    await Clipboard.setData(ClipboardData(text: texto));
    if (mounted) AppToast.show(context, 'Registro copiado al portapapeles');
  }

  Future<void> _limpiarAuditoria() async {
    if (!await _pedirPassword(context)) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar auditoría'),
        content: const Text(
            '¿Eliminar TODO el registro de auditoría?\n\nEsta acción no se puede deshacer.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LogService.limpiarAuditoria();
    await _cargar();
    if (mounted) AppToast.show(context, 'Auditoría borrada');
  }

  Future<void> _eliminarInventario(_Inventario inv) async {
    if (!await _pedirPassword(context)) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar inventario'),
        content: Text(
            '¿Eliminar el inventario del ${_fmtDia.format(inv.cab.fechaOperacion)} '
            'con ${inv.lineas.length} líneas?\n\nSolo se borra de la tablet, no del servidor.'),
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
    if (ok != true) return;
    await _db.deleteInventario(inv.cab.id);
    LogService.auditar(
        'ELIMINADO inventario ${_fmtDia.format(inv.cab.fechaOperacion)} '
        'alm ${inv.cab.almacenId} (${inv.lineas.length} líneas) de la tablet');
    await _cargar();
    if (mounted) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop(); // detalle
      AppToast.show(context, 'Inventario eliminado de la tablet');
    }
  }

  Future<void> _reenviarInventario(_Inventario inv) async {
    if (!ConfigService.isLegacyMode) {
      AppToast.show(context, 'Reenvío solo disponible en modo legacy', error: true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Reenviar inventario'),
        content: const Text(
            'Reenviar vuelve a aplicar las diferencias contra el servidor.\n\n'
            'Úsalo SOLO si el envío anterior falló. Si el envío anterior llegó '
            'a aplicarse, reenviar duplicaría los ajustes de stock.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reenviar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final res = await LegacyService(_db).enviar(inv.cab, inv.lineas);
      await _db.cerrarCabecera(inv.cab.id);
      LogService.auditar(
          'REENVÍO inventario ${_fmtDia.format(inv.cab.fechaOperacion)} '
          'alm ${inv.cab.almacenId}: ${res.inventariados} artículos, '
          '${res.movimientos} movimientos');
      if (mounted) {
        Navigator.of(context).pop(); // progreso
        AppToast.show(context,
            'Reenviado: ${res.inventariados} artículos, ${res.movimientos} movimientos');
      }
      await _cargar();
    } catch (e) {
      final msg = LogService.traducirError(e);
      LogService.registrar('Reenvío de inventario: $msg', isError: true);
      if (mounted) {
        Navigator.of(context).pop(); // progreso
        AppToast.show(context, msg, error: true);
      }
    }
  }

  Future<void> _limpiarIncidencias() async {
    if (!await _pedirPassword(context)) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Limpiar incidencias'),
        content: const Text('¿Eliminar todos los mensajes de incidencias?\n\nEl registro de auditoría NO se borrará.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Limpiar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LogService.limpiar();
    await _cargar();
    if (mounted) AppToast.show(context, 'Incidencias limpiadas');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entradas = _entradas;
    final errores = _incidencias.where((e) => e.isError).length;
    final esAuditoria = _vista == 'auditoria';
    final esInventarios = _vista == 'inventarios';
    final copiable = esInventarios ? _inventarios.isNotEmpty : entradas.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        foregroundColor: cs.onSurface,
        title: const Text('Registros'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.copy_all),
            tooltip: 'Copiar todo',
            onPressed: copiable ? _copiarTodo : null,
          ),
          if (_vista == 'incidencias')
            IconButton(
              icon: Icon(Symbols.delete_sweep, color: cs.error),
              tooltip: 'Limpiar incidencias',
              onPressed: _incidencias.isEmpty ? null : _limpiarIncidencias,
            ),
          if (esAuditoria)
            IconButton(
              icon: Icon(Symbols.delete_forever, color: cs.error),
              tooltip: 'Borrar auditoría (contraseña)',
              onPressed: _auditoria.isEmpty ? null : _limpiarAuditoria,
            ),
          IconButton(
            icon: const Icon(Symbols.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // ── Selector de vista ────────────────────────────────────
          Container(
            color: cs.surfaceContainerLowest,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(
              children: [
                _Chip(
                  label: 'Incidencias',
                  count: _incidencias.length,
                  selected: !esAuditoria,
                  color: cs.primary,
                  onTap: () => setState(() => _vista = 'incidencias'),
                ),
                const SizedBox(width: 8),
                _Chip(
                  label: 'Auditoría',
                  count: _auditoria.length,
                  selected: esAuditoria,
                  color: Colors.green.shade700,
                  onTap: () => setState(() => _vista = 'auditoria'),
                ),
                const SizedBox(width: 8),
                _Chip(
                  label: 'Inventarios',
                  count: _inventarios.length,
                  selected: esInventarios,
                  color: Colors.indigo.shade400,
                  onTap: () => setState(() => _vista = 'inventarios'),
                ),
                const Spacer(),
                if (esAuditoria)
                  Row(
                    children: [
                      Icon(Symbols.lock, size: 13, color: cs.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text('Solo lectura',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                    ],
                  ),
              ],
            ),
          ),

          // ── Sub-filtro (solo en vista incidencias) ───────────────
          if (_vista == 'incidencias')
            Container(
              color: cs.surfaceContainerLowest,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                children: [
                  _Chip(
                    label: 'Todos',
                    count: _incidencias.length,
                    selected: !_soloErrores,
                    color: cs.onSurfaceVariant,
                    onTap: () => setState(() => _soloErrores = false),
                  ),
                  const SizedBox(width: 8),
                  _Chip(
                    label: 'Solo errores',
                    count: errores,
                    selected: _soloErrores,
                    color: cs.error,
                    onTap: () => setState(() => _soloErrores = true),
                  ),
                  const Spacer(),
                  if (!_cargando)
                    Text(
                      '${entradas.length} mensaje${entradas.length == 1 ? '' : 's'}',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),

          Divider(height: 1, color: cs.outlineVariant),

          // ── Lista ───────────────────────────────────────────────
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : esInventarios
                    ? _inventarios.isEmpty
                        ? _EmptyState(
                            icon: Symbols.inventory_2,
                            texto: 'Sin inventarios todavía',
                            theme: theme)
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            itemCount: _inventarios.length,
                            itemBuilder: (ctx, i) => _InventarioCard(
                              inventario: _inventarios[i],
                              theme: theme,
                              onTap: () {
                                final inv = _inventarios[i];
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => _InventarioDetalleScreen(
                                      inventario: inv,
                                      onReenviar: () => _reenviarInventario(inv),
                                      onEliminar: () => _eliminarInventario(inv),
                                    ),
                                  ),
                                );
                              },
                            ),
                          )
                    : entradas.isEmpty
                        ? _EmptyState(
                            icon: esAuditoria
                                ? Symbols.assignment
                                : Symbols.check_circle,
                            texto: esAuditoria
                                ? 'Sin movimientos registrados todavía'
                                : _soloErrores
                                    ? 'Sin errores registrados'
                                    : 'El registro está vacío',
                            theme: theme)
                        : ListView.builder(
                            itemCount: entradas.length,
                            itemBuilder: (ctx, i) =>
                                _EntradaRow(entry: entradas[i], theme: theme),
                          ),
          ),
        ],
      ),
    );
  }
}

// ── Estado vacío ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String texto;
  final ThemeData theme;

  const _EmptyState(
      {required this.icon, required this.texto, required this.theme});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: cs.outlineVariant),
          const SizedBox(height: 16),
          Text(texto,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ── Tarjeta de inventario (vista histórico) ───────────────────────────────────

class _EstadoBadge extends StatelessWidget {
  final bool sincronizado;
  const _EstadoBadge({required this.sincronizado});

  @override
  Widget build(BuildContext context) {
    final color =
        sincronizado ? Colors.green.shade700 : Colors.orange.shade800;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        sincronizado ? 'Enviado' : 'Pendiente',
        style:
            TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _InventarioCard extends StatelessWidget {
  final _Inventario inventario;
  final ThemeData theme;
  final VoidCallback onTap;

  const _InventarioCard(
      {required this.inventario, required this.theme, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final cab = inventario.cab;
    final lineas = inventario.lineas;
    final articulos = lineas.map((l) => l.articuloId).toSet().length;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withAlpha(120)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.indigo.withAlpha(18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Symbols.inventory_2,
                    color: Colors.indigo.shade400, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Inventario ${_fmtDia.format(cab.fechaOperacion)}',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Almacén ${cab.almacenId} · $articulos artículo${articulos == 1 ? '' : 's'} · ${lineas.length} línea${lineas.length == 1 ? '' : 's'}',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    if (cab.sincronizado && cab.fechaSync != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Enviado el ${_fmtDiaHora.format(cab.fechaSync!)}',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _EstadoBadge(sincronizado: cab.sincronizado),
              Icon(Symbols.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Detalle de inventario (líneas) ────────────────────────────────────────────

class _InventarioDetalleScreen extends StatelessWidget {
  final _Inventario inventario;
  final VoidCallback onReenviar;
  final VoidCallback onEliminar;

  const _InventarioDetalleScreen({
    required this.inventario,
    required this.onReenviar,
    required this.onEliminar,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final cab = inventario.cab;
    final lineas = [...inventario.lineas]..sort((a, b) {
        final c = a.articuloCodigo.compareTo(b.articuloCodigo);
        return c != 0 ? c : (a.codigoLote ?? '').compareTo(b.codigoLote ?? '');
      });
    final articulos = lineas.map((l) => l.articuloId).toSet().length;
    final totalUnidades = lineas.fold<double>(0, (s, l) => s + l.stock);

    return Scaffold(
      appBar: AppBar(
        foregroundColor: cs.onSurface,
        title: Text('Inventario ${_fmtDia.format(cab.fechaOperacion)}'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.send),
            tooltip: 'Reenviar a la central',
            onPressed: onReenviar,
          ),
          IconButton(
            icon: Icon(Symbols.delete, color: cs.error),
            tooltip: 'Eliminar de la tablet (contraseña)',
            onPressed: onEliminar,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: _EstadoBadge(sincronizado: cab.sincronizado)),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Resumen ─────────────────────────────────────────────
          Container(
            width: double.infinity,
            color: cs.surfaceContainerLowest,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                _Resumen(valor: 'Alm. ${cab.almacenId}', label: 'almacén', cs: cs),
                _Resumen(valor: '$articulos', label: 'artículos', cs: cs),
                _Resumen(valor: '${lineas.length}', label: 'líneas', cs: cs),
                _Resumen(
                    valor: _fmtCant(totalUnidades), label: 'unidades', cs: cs),
              ],
            ),
          ),
          if (cab.sincronizado && cab.fechaSync != null)
            Container(
              width: double.infinity,
              color: cs.surfaceContainerLowest,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                'Enviado a la central el ${_fmtDiaHora.format(cab.fechaSync!)}',
                style: TextStyle(fontSize: 12, color: Colors.green.shade700),
              ),
            ),
          Divider(height: 1, color: cs.outlineVariant),

          // ── Líneas ──────────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              itemCount: lineas.length,
              itemBuilder: (ctx, i) {
                final l = lineas[i];
                final tieneLote = (l.codigoLote ?? '').isNotEmpty &&
                    l.codigoLote != 'SIN_LOTE';
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: cs.outlineVariant.withAlpha(60))),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${l.articuloCodigo}  ${l.articuloDescripcion}',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface),
                            ),
                            if (tieneLote || l.fechaCaducidad != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                [
                                  if (tieneLote) 'Lote ${l.codigoLote}',
                                  if (l.fechaCaducidad != null)
                                    'Cad. ${_fmtDia.format(l.fechaCaducidad!)}',
                                ].join(' · '),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _fmtCant(l.stock),
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.indigo.shade400),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Resumen extends StatelessWidget {
  final String valor;
  final String label;
  final ColorScheme cs;

  const _Resumen({required this.valor, required this.label, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(valor,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface)),
          Text(label,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ── Chip de filtro ────────────────────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.count,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? color.withAlpha(22) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? color : cs.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? color : cs.onSurfaceVariant)),
            const SizedBox(width: 5),
            Text('$count',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? color : cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

// ── Fila de entrada ───────────────────────────────────────────────────────────

class _EntradaRow extends StatelessWidget {
  final LogEntry entry;
  final ThemeData theme;

  const _EntradaRow({required this.entry, required this.theme});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final color = entry.isError
        ? cs.error
        : entry.isAudit
            ? Colors.green.shade700
            : cs.onSurfaceVariant;
    final bgColor = entry.isError
        ? cs.error.withAlpha(10)
        : entry.isAudit
            ? Colors.green.withAlpha(10)
            : Colors.transparent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        border:
            Border(bottom: BorderSide(color: cs.outlineVariant.withAlpha(60))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            entry.isError
                ? Symbols.error
                : entry.isAudit
                    ? Symbols.assignment_turned_in
                    : Symbols.info,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.mensaje,
                  style: TextStyle(
                    fontSize: 13,
                    color: entry.isError ? cs.error : cs.onSurface,
                    fontWeight: entry.isError
                        ? FontWeight.w500
                        : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _fmtTs.format(entry.timestamp),
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
