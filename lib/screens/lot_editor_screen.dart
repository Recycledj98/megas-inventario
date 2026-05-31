import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:drift/drift.dart' show Value;
import '../database/database.dart';
import '../database/tables.dart';
import '../services/config_service.dart';
import '../services/feedback_service.dart';
import '../services/legacy_service.dart';
import '../services/log_service.dart';
import '../widgets/app_toast.dart';

final _fmtNum = NumberFormat('#,##0.##', 'es_ES');
final _fmtDate = DateFormat('dd/MM/yyyy');

/// Pantalla completa de edición de lotes e inventario de un artículo.
/// Se muestra como Dialog. Devuelve `true` si hubo cambios.
class LotEditorScreen extends StatefulWidget {
  final ArticulosLocalData articulo;
  final CabecerasInventarioLocalData cabecera;

  const LotEditorScreen({
    super.key,
    required this.articulo,
    required this.cabecera,
  });

  @override
  State<LotEditorScreen> createState() => _LotEditorScreenState();
}

class _LotEditorScreenState extends State<LotEditorScreen> {
  final _db = AppDatabase();
  List<LineasInventarioLocalData> _lineas = [];
  List<StockLotesLocalData> _lotes = [];
  bool _changed = false;
  String _activeTab = 'sesion';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lineas = await _db.getLineasPorArticulo(
        widget.cabecera.id, widget.articulo.articuloId);
    final lotes = await _db.getStockLotes(
        ConfigService.empresaId, widget.articulo.articuloId);
    if (mounted) {
      setState(() {
        _lineas = lineas;
        _lotes = lotes;
      });
    }
  }

  double get _totalInventariado =>
      _lineas.fold(0.0, (sum, l) => sum + l.stock);

  double get _stockActual =>
      _lotes.fold(0.0, (sum, l) => sum + l.stock);

  Future<void> _openLineaDialog({
    LineasInventarioLocalData? editing,
    String? preselLote,
    DateTime? preselCad,
  }) async {
    final result = await showDialog<_LineaResult>(
      barrierDismissible: false,
      context: context,
      builder: (_) => _DialogLinea(
        articulo: widget.articulo,
        stockActual: _stockActual,
        preselLote: editing?.codigoLote ?? preselLote,
        preselCad: editing?.fechaCaducidad ?? preselCad,
        preselQty: editing?.stock,
        editing: editing,
      ),
    );
    if (result == null || !mounted) return;

    if (editing != null) {
      await _db.updateLinea(
          editing.id, result.qty, result.lote, result.fechaCaducidad);
    } else {
      await _db.insertLinea(LineasInventarioLocalCompanion(
        cabeceraId: Value(widget.cabecera.id),
        articuloId: Value(widget.articulo.articuloId),
        articuloDescripcion: Value(
            widget.articulo.descripcion1 ?? widget.articulo.descripcion2 ?? ''),
        articuloCodigo: Value(widget.articulo.identificacion),
        almacenId: Value(widget.cabecera.almacenId),
        stock: Value(result.qty),
        codigoLote: Value(result.lote),
        fechaCaducidad: Value(result.fechaCaducidad),
        fechaAlta: Value(DateTime.now()),
      ));
    }
    _changed = true;
    FeedbackService.success();
    await _load();
  }

  Future<void> _openArticuloEdit() async {
    final art = widget.articulo;
    final result = await showDialog<ArticuloEditResult>(
      barrierDismissible: false,
      context: context,
      builder: (_) => ArticuloEditDialog(articulo: art),
    );
    if (result == null || !mounted) return;
    // Actualizar BD local
    await _db.updateArticuloFields(
      ConfigService.isLegacyMode ? 0 : ConfigService.empresaId,
      art.articuloId,
      cbarra:    result.cbarra,
      ubicacion: result.ubicacion,
      peso:      result.peso,
      unicaj:    result.unicaj,
      unipal:    result.unipal,
    );
    if (ConfigService.isLegacyMode) {
      // Escribir a ARTICULO.DBF vía SMB
      try {
        final svc = LegacyService(_db);
        await svc.saveArticuloFields(
          art.identificacion,
          cbarra:    result.cbarra,
          ubicacion: result.ubicacion,
          peso:      result.peso,
          unicaj:    result.unicaj,
          unipal:    result.unipal,
        );
        if (mounted) AppToast.show(context, 'Artículo guardado');
      } catch (e) {
        LogService.registrar('Error al guardar artículo «${art.identificacion}» en servidor: ${LogService.traducirError(e)}', isError: true);
        if (mounted) {
          AppToast.show(context, 'Error al guardar en el servidor: ${_simplifyError(e)}', error: true);
        }
      }
    } else {
      if (mounted) AppToast.show(context, 'Artículo guardado');
    }
  }

  Future<void> _deleteLinea(LineasInventarioLocalData linea) async {
    final ok = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar línea'),
        content: const Text('¿Eliminar este conteo?'),
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
    _changed = true;
    FeedbackService.tap();
    await _load();
  }

  Widget _buildSesionContent(ThemeData theme, ColorScheme cs) {
    if (_lineas.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Text(
            'Sin líneas en esta sesión.\nUsa «Lotes en stock» o el botón Añadir.',
            style: TextStyle(color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      children: _lineas
          .map((l) => _LineaTableRow(
                linea: l,
                theme: theme,
                onEdit: () => _openLineaDialog(editing: l),
                onDelete: () => _deleteLinea(l),
              ))
          .toList(),
    );
  }

  Widget _buildLotesContent(ThemeData theme, ColorScheme cs) {
    if (_lotes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Text(
            'Sin lotes en stock para este artículo.\n'
            'Sincroniza el stock desde Configuración.',
            style: TextStyle(color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      children: _lotes.map((sl) {
        final lineaDelLote =
            _lineas.where((l) => l.codigoLote == sl.codigoLote).firstOrNull;
        return _LoteTableRow(
          lote: sl,
          theme: theme,
          lineaExistente: lineaDelLote,
          onAnadir: () => _openLineaDialog(
            preselLote:
                sl.codigoLote != 'SIN_LOTE' ? sl.codigoLote : null,
            preselCad:
                sl.fechaCaducidad.year < 2090 ? sl.fechaCaducidad : null,
          ),
          onEditar: lineaDelLote != null
              ? () => _openLineaDialog(editing: lineaDelLote)
              : null,
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final art = widget.articulo;

    return Scaffold(
          appBar: AppBar(
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            leading: BackButton(onPressed: () => Navigator.pop(context)),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  art.identificacion,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
                Text(
                  art.descripcion1 ?? art.descripcion2 ?? '',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              if (ConfigService.isLegacyMode)
                IconButton(
                  icon: const Icon(Symbols.tune),
                  tooltip: 'Editar datos artículo',
                  onPressed: () => _openArticuloEdit(),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Total inventariado',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    Text(
                      '${_fmtNum.format(_totalInventariado)} uds',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Lista principal ──────────────────────────────────
              Expanded(
                child: Column(
                  children: [
                    _TabSelector(
                      lineasCount: _lineas.length,
                      lotesCount: _lotes.length,
                      activeTab: _activeTab,
                      theme: theme,
                      onChanged: (tab) => setState(() => _activeTab = tab),
                    ),
                    _LoteTableHeader(
                        theme: theme, showStock: _activeTab == 'lotes'),
                    Divider(height: 1, thickness: 1, color: cs.outlineVariant),
                    Expanded(
                      child: _activeTab == 'sesion'
                          ? _buildSesionContent(theme, cs)
                          : _buildLotesContent(theme, cs),
                    ),
                  ],
                ),
              ),
              // ── Panel de acciones (derecha) ──────────────────────
              Container(
                width: 110,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  border: Border(left: BorderSide(color: cs.outlineVariant)),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: _PanelBtn(
                        icon: Symbols.add_circle,
                        label: 'Añadir\ncantidad',
                        color: cs.primary,
                        onTap: () => _openLineaDialog(),
                      ),
                    ),
                    Divider(height: 1, color: cs.outlineVariant),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 8),
                      child: Column(
                        children: [
                          Text(
                            'Stock total',
                            style: TextStyle(
                                fontSize: 10, color: cs.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _fmtNum.format(_stockActual),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: _stockActual < 0
                                  ? cs.error
                                  : _stockActual == 0
                                      ? Colors.amber.shade700
                                      : cs.onSurface,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            'uds',
                            style: TextStyle(
                                fontSize: 10, color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
    );
  }
}

// ── Anchos de columna de la tabla de lotes ────────────────────────────────────

const _wCad = 92.0;
const _wCant = 70.0;
const _wAcciones = 88.0;
const _lotColGap = 6.0;

// ── Selector de pestaña (estilo _ConteoFilterRow de HomeScreen) ───────────────

class _TabSelector extends StatelessWidget {
  final int lineasCount;
  final int lotesCount;
  final String activeTab;
  final ValueChanged<String> onChanged;
  final ThemeData theme;

  const _TabSelector({
    required this.lineasCount,
    required this.lotesCount,
    required this.activeTab,
    required this.onChanged,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      height: 34,
      color: cs.surfaceContainerLowest,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _chip(context, 'sesion', 'En sesión', lineasCount,
              lineasCount > 0 ? cs.primary : cs.onSurfaceVariant, cs),
          const SizedBox(width: 6),
          _chip(context, 'lotes', 'Lotes en stock', lotesCount,
              cs.onSurfaceVariant, cs),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String value, String label, int count,
      Color color, ColorScheme cs) {
    final selected = activeTab == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
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
                  fontSize: 11,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? color : cs.onSurfaceVariant,
                )),
            const SizedBox(width: 4),
            Text('$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: selected ? color : cs.onSurfaceVariant,
                )),
          ],
        ),
      ),
    );
  }
}

// ── Cabecera de tabla de lotes ────────────────────────────────────────────────

class _LoteTableHeader extends StatelessWidget {
  final ThemeData theme;
  final bool showStock;
  const _LoteTableHeader({required this.theme, required this.showStock});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );
    return Container(
      height: 30,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Text('Código lote', style: style)),
          const SizedBox(width: _lotColGap),
          SizedBox(
              width: _wCad,
              child: Text('Caducidad', style: style, textAlign: TextAlign.center)),
          const SizedBox(width: _lotColGap),
          SizedBox(
              width: _wCant,
              child: Text(showStock ? 'Stock' : 'Cantidad',
                  style: style, textAlign: TextAlign.right)),
          const SizedBox(width: _wAcciones),
        ],
      ),
    );
  }
}

// ── Fila de línea contada (tabla) ─────────────────────────────────────────────

class _LineaTableRow extends StatelessWidget {
  final LineasInventarioLocalData linea;
  final ThemeData theme;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LineaTableRow({
    required this.linea,
    required this.theme,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final lote = linea.codigoLote;
    final cad = linea.fechaCaducidad;
    final isReal = lote != null && lote != 'SIN_LOTE';

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: cs.outlineVariant.withAlpha(80))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (isReal) ...[
                  Icon(Symbols.tag, size: 13, color: cs.onSurfaceVariant),
                  const SizedBox(width: 3),
                ],
                Expanded(
                  child: Text(
                    isReal ? lote ?? '' : 'Sin lote',
                    style: TextStyle(
                      fontWeight:
                          isReal ? FontWeight.w500 : FontWeight.w400,
                      color: isReal ? cs.onSurface : cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _lotColGap),
          SizedBox(
            width: _wCad,
            child: Text(
              cad != null && cad.year < 2090
                  ? _fmtDate.format(cad)
                  : '—',
              style:
                  TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: _lotColGap),
          SizedBox(
            width: _wCant,
            child: Text(
              _fmtNum.format(linea.stock),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: cs.primary,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: _wAcciones,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Symbols.edit, size: 18),
                  onPressed: onEdit,
                  tooltip: 'Editar',
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                ),
                IconButton(
                  icon: Icon(Symbols.delete, size: 18, color: cs.error),
                  onPressed: onDelete,
                  tooltip: 'Eliminar',
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Fila de lote en stock (tabla) ─────────────────────────────────────────────

class _LoteTableRow extends StatelessWidget {
  final StockLotesLocalData lote;
  final ThemeData theme;
  final LineasInventarioLocalData? lineaExistente;
  final VoidCallback onAnadir;
  final VoidCallback? onEditar;

  const _LoteTableRow({
    required this.lote,
    required this.theme,
    required this.onAnadir,
    this.lineaExistente,
    this.onEditar,
  });

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    final cad = lote.fechaCaducidad;
    final isReal = lote.codigoLote != 'SIN_LOTE';
    final tieneApunte = lineaExistente != null;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tieneApunte ? cs.primary.withAlpha(14) : null,
        border:
            Border(bottom: BorderSide(color: cs.outlineVariant.withAlpha(80))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      isReal ? Symbols.tag : Symbols.inventory_2,
                      size: 15,
                      color:
                          tieneApunte ? cs.primary : cs.onSurfaceVariant,
                    ),
                    if (tieneApunte)
                      Positioned(
                        right: -4,
                        bottom: -3,
                        child: Icon(Symbols.check_circle,
                            size: 9, color: cs.primary),
                      ),
                  ],
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    isReal ? lote.codigoLote : 'Sin lote',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: tieneApunte ? cs.primary : cs.onSurface,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _lotColGap),
          SizedBox(
            width: _wCad,
            child: Text(
              cad.year < 2090 ? _fmtDate.format(cad) : '—',
              style:
                  TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: _lotColGap),
          SizedBox(
            width: _wCant,
            child: Text(
              _fmtNum.format(lote.stock),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: _wAcciones,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (tieneApunte)
                  IconButton(
                    icon: Icon(Symbols.edit, size: 18, color: cs.primary),
                    tooltip: 'Editar apunte',
                    onPressed: onEditar,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                  ),
                FilledButton.tonal(
                  onPressed: onAnadir,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(52, 30),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(tieneApunte ? 'Anotar' : 'Añadir',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Diálogo de línea (añadir / editar) ───────────────────────────────────────

class _LineaResult {
  final double qty;
  final String? lote;
  final DateTime? fechaCaducidad;
  const _LineaResult(this.qty, this.lote, this.fechaCaducidad);
}

class _DialogLinea extends StatefulWidget {
  final ArticulosLocalData articulo;
  final double stockActual;
  final LineasInventarioLocalData? editing;
  final String? preselLote;
  final DateTime? preselCad;
  final double? preselQty;

  const _DialogLinea({
    required this.articulo,
    required this.stockActual,
    this.editing,
    this.preselLote,
    this.preselCad,
    this.preselQty,
  });

  @override
  State<_DialogLinea> createState() => _DialogLineaState();
}

class _DialogLineaState extends State<_DialogLinea> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _loteCtrl;
  DateTime? _fechaCaducidad;

  @override
  void initState() {
    super.initState();
    final qty = widget.preselQty;
    _qtyCtrl = TextEditingController(
      text: qty != null
          ? (qty == qty.truncateToDouble()
              ? qty.toInt().toString()
              : qty.toString())
          : '',
    );
    final lote = widget.preselLote;
    _loteCtrl = TextEditingController(
        text: (lote != null && lote != 'SIN_LOTE') ? lote : '');
    final cad = widget.preselCad;
    if (cad != null && cad.year < 2090) _fechaCaducidad = cad;
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _loteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFecha() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fechaCaducidad ??
          DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now(),
      lastDate: DateTime(2099),
    );
    if (picked != null && mounted) {
      setState(() => _fechaCaducidad = picked);
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final qty =
        double.tryParse(_qtyCtrl.text.trim().replaceAll(',', '.'));
    if (qty == null) return;
    final lote =
        _loteCtrl.text.trim().isEmpty ? null : _loteCtrl.text.trim();
    Navigator.pop(context,
        _LineaResult(qty, lote, _fechaCaducidad));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final art = widget.articulo;
    final isEdit = widget.editing != null;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Builder(builder: (ctx) {
        final kb   = MediaQuery.viewInsetsOf(ctx).bottom;
        final maxH = (MediaQuery.of(ctx).size.height - kb - 40).clamp(220.0, 700.0);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: maxH),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEdit ? 'Editar conteo' : 'Añadir cantidad',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface),
                ),
                const SizedBox(height: 12),
                Text(art.identificacion,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                        fontSize: 16)),
                const SizedBox(height: 4),
                Text(art.descripcion1 ?? art.descripcion2 ?? '',
                    style:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),

                // Stock actual
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Stock actual',
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 13)),
                      Text(
                        _fmtNum.format(widget.stockActual),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: widget.stockActual < 0
                              ? cs.error
                              : widget.stockActual == 0
                                  ? Colors.amber.shade700
                                  : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Cantidad
                TextFormField(
                  controller: _qtyCtrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: false),
                  style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 26,
                      fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                      labelText: 'Cantidad', suffixText: 'uds'),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Introduce la cantidad';
                    }
                    if (double.tryParse(
                            v.trim().replaceAll(',', '.')) ==
                        null) {
                      return 'Número no válido';
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),

                // Lote
                TextField(
                  controller: _loteCtrl,
                  style: TextStyle(color: cs.onSurface),
                  keyboardType: TextInputType.text,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Código lote (opcional)',
                    prefixIcon: const Icon(Symbols.tag),
                    suffixIcon: _loteCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Symbols.close, size: 18),
                            onPressed: () => setState(() => _loteCtrl.clear()),
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),

                // Caducidad
                OutlinedButton.icon(
                  onPressed: _pickFecha,
                  icon: const Icon(Symbols.calendar_month, size: 18),
                  label: Text(_fechaCaducidad != null
                      ? 'Cad: ${_fmtDate.format(_fechaCaducidad!)}'
                      : 'Fecha de caducidad (opcional)'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _fechaCaducidad != null
                        ? cs.primary
                        : cs.onSurfaceVariant,
                  ),
                ),
                if (_fechaCaducidad != null)
                  TextButton(
                    onPressed: () =>
                        setState(() => _fechaCaducidad = null),
                    child: const Text('Quitar caducidad'),
                  ),

                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancelar')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _submit,
                      child: const Text('Guardar'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      );
      }),
    );
  }
}

// ── Edición de campos de artículo ─────────────────────────────────────────────

class ArticuloEditResult {
  final String? cbarra;
  final String? ubicacion;
  final double? peso;
  final double? unicaj;
  final double? unipal;
  const ArticuloEditResult({this.cbarra, this.ubicacion, this.peso, this.unicaj, this.unipal});
}

class ArticuloEditDialog extends StatefulWidget {
  final ArticulosLocalData articulo;
  const ArticuloEditDialog({super.key, required this.articulo});
  @override
  State<ArticuloEditDialog> createState() => _ArticuloEditDialogState();
}

class _ArticuloEditDialogState extends State<ArticuloEditDialog> {
  late final TextEditingController _cbarraCtrl;
  late final TextEditingController _ubicacionCtrl;
  late final TextEditingController _pesoCtrl;
  late final TextEditingController _unicajCtrl;
  late final TextEditingController _unipalCtrl;

  @override
  void initState() {
    super.initState();
    final a = widget.articulo;
    _cbarraCtrl    = TextEditingController(text: a.codigoAlternativo1 ?? '');
    _ubicacionCtrl = TextEditingController(text: a.ubicacion ?? '');
    _pesoCtrl      = TextEditingController(text: a.peso   != null ? _fmtNum.format(a.peso)   : '');
    _unicajCtrl    = TextEditingController(text: a.unicaj != null ? _fmtNum.format(a.unicaj) : '');
    _unipalCtrl    = TextEditingController(text: a.unipal != null ? _fmtNum.format(a.unipal) : '');
  }

  @override
  void dispose() {
    _cbarraCtrl.dispose(); _ubicacionCtrl.dispose();
    _pesoCtrl.dispose(); _unicajCtrl.dispose(); _unipalCtrl.dispose();
    super.dispose();
  }

  void _selectAll(TextEditingController c) {
    c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
  }

  double? _parseNum(String s) =>
      double.tryParse(s.trim().replaceAll(',', '.').replaceAll('.', '.'));

  void _submit() {
    Navigator.pop(context, ArticuloEditResult(
      cbarra:    _cbarraCtrl.text.trim().isEmpty    ? null : _cbarraCtrl.text.trim(),
      ubicacion: _ubicacionCtrl.text.trim().isEmpty ? null : _ubicacionCtrl.text.trim(),
      peso:      _parseNum(_pesoCtrl.text),
      unicaj:    _parseNum(_unicajCtrl.text),
      unipal:    _parseNum(_unipalCtrl.text),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final art = widget.articulo;

    InputDecoration _dec(String label, {String? hint, IconData? icon}) =>
        InputDecoration(
          labelText: label, hintText: hint,
          prefixIcon: icon != null ? Icon(icon, size: 20) : null,
          isDense: false,
        );

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Builder(builder: (ctx) {
        final kb   = MediaQuery.viewInsetsOf(ctx).bottom;
        final maxH = (MediaQuery.of(ctx).size.height - kb - 40).clamp(220.0, 700.0);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480, maxHeight: maxH),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Editar artículo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const SizedBox(height: 4),
              Text('${art.identificacion}  ${art.descripcion1 ?? ''}',
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 20),
              TextField(
                controller: _cbarraCtrl,
                style: TextStyle(color: cs.onSurface),
                decoration: _dec('Código de barras', icon: Symbols.qr_code),
                keyboardType: TextInputType.text,
                onTap: () => _selectAll(_cbarraCtrl),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ubicacionCtrl,
                style: TextStyle(color: cs.onSurface),
                decoration: _dec('Ubicación', hint: 'A-01-2', icon: Symbols.location_on),
                keyboardType: TextInputType.text,
                textCapitalization: TextCapitalization.characters,
                onTap: () => _selectAll(_ubicacionCtrl),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pesoCtrl,
                      style: TextStyle(color: cs.onSurface),
                      decoration: _dec('Peso (kg)', icon: Symbols.weight),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onTap: () => _selectAll(_pesoCtrl),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _unicajCtrl,
                    style: TextStyle(color: cs.onSurface),
                    decoration: _dec('Uds/Caja', icon: Symbols.inventory_2),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onTap: () => _selectAll(_unicajCtrl),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _unipalCtrl,
                    style: TextStyle(color: cs.onSurface),
                    decoration: _dec('Uds/Palet', icon: Symbols.pallet),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onTap: () => _selectAll(_unipalCtrl),
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancelar')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Symbols.save, size: 18),
                    label: const Text('Guardar'),
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


// ── Botón de panel lateral ────────────────────────────────────────────────────

class _PanelBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _PanelBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.color,
  });

  @override
  State<_PanelBtn> createState() => _PanelBtnState();
}

class _PanelBtnState extends State<_PanelBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        width: double.infinity,
        height: double.infinity,
        color: _pressed ? widget.color.withAlpha(55) : Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, color: widget.color, size: 34),
            const SizedBox(height: 8),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 11,
                color: widget.color,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

String _simplifyError(Object e) {
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Connection refused')) {
    return 'No se puede conectar al servidor';
  }
  if (s.contains('TimeoutException') || s.contains('timeout')) {
    return 'Tiempo de conexion agotado';
  }
  if (s.contains('SMB') || s.contains('smb')) return 'Error de conexion SMB';
  return s.length > 100 ? s.substring(0, 100) + '...' : s;
}
