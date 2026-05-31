import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../services/log_service.dart';
import '../widgets/app_toast.dart';

final _fmtTs = DateFormat('dd/MM HH:mm:ss');

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  // 'incidencias' | 'auditoria'
  String _vista = 'incidencias';

  List<LogEntry> _incidencias = [];
  List<LogEntry> _auditoria = [];
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
    if (mounted) {
      setState(() {
        _incidencias = results[0];
        _auditoria = results[1];
        _cargando = false;
      });
    }
  }

  List<LogEntry> get _incidenciasFiltradas =>
      _soloErrores ? _incidencias.where((e) => e.isError).toList() : _incidencias;

  List<LogEntry> get _entradas =>
      _vista == 'auditoria' ? _auditoria : _incidenciasFiltradas;

  Future<void> _copiarTodo() async {
    final lineas = _entradas.map((e) {
      final prefijo = e.isAudit ? '📋' : e.isError ? '❌' : '✓';
      return '$prefijo [${_fmtTs.format(e.timestamp)}] ${e.mensaje}';
    }).join('\n');
    await Clipboard.setData(ClipboardData(text: lineas));
    if (mounted) AppToast.show(context, 'Registro copiado al portapapeles');
  }

  Future<void> _limpiarIncidencias() async {
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

    return Scaffold(
      appBar: AppBar(
        foregroundColor: cs.onSurface,
        title: const Text('Registros'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.copy_all),
            tooltip: 'Copiar todo',
            onPressed: entradas.isEmpty ? null : _copiarTodo,
          ),
          if (!esAuditoria)
            IconButton(
              icon: Icon(Symbols.delete_sweep, color: cs.error),
              tooltip: 'Limpiar incidencias',
              onPressed: _incidencias.isEmpty ? null : _limpiarIncidencias,
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
          if (!esAuditoria)
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
                : entradas.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              esAuditoria
                                  ? Symbols.assignment
                                  : Symbols.check_circle,
                              size: 64,
                              color: cs.outlineVariant,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              esAuditoria
                                  ? 'Sin movimientos registrados todavía'
                                  : _soloErrores
                                      ? 'Sin errores registrados'
                                      : 'El registro está vacío',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      )
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
