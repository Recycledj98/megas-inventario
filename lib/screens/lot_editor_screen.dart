import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:drift/drift.dart' show Value;
import '../database/database.dart';
import '../database/tables.dart';
import '../services/config_service.dart';
import '../services/feedback_service.dart';
import '../services/legacy_service.dart';
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
      context: context,
      builder: (_) => ArticuloEditDialog(articulo: art),
    );
    if (result == null || !mounted) return;
    // Actualizar BD local
    await _db.updateArticuloFields(
      ConfigService.isLegacyMode ? 0 : ConfigService.empresaId,
      art.articuloId,
      cbarra: result.cbarra,
      peso:   result.peso,
      unicaj: result.unicaj,
      unipal: result.unipal,
    );
    // Escribir a ARTICULO.DBF vía SMB
    try {
      final svc = LegacyService(_db);
      await svc.saveArticuloFields(
        art.identificacion,
        cbarra: result.cbarra,
        peso:   result.peso,
        unicaj: result.unicaj,
        unipal: result.unipal,
      );
      if (mounted) AppToast.show(context, 'Artículo guardado');
    } catch (e) {
      if (mounted) {
        AppToast.show(context, 'Error al guardar en el servidor: ${_simplifyError(e)}', error: true);
      }
    }
  }

  Future<void> _deleteLinea(LineasInventarioLocalData linea) async {
    final ok = await showDialog<bool>(
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
          body: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              // ── Contado en sesión ──────────────────────────────
              _SectionHeader(label: 'CONTADO EN SESIÓN', theme: theme),
              if (_lineas.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 20),
                  child: Text(
                    'Sin líneas en esta sesión.\nUsa los lotes de abajo o añade una cantidad nueva.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                ..._lineas.map((l) => _LineaRow(
                      linea: l,
                      theme: theme,
                      onEdit: () => _openLineaDialog(editing: l),
                      onDelete: () => _deleteLinea(l),
                    )),

              // ── Lotes en stock ─────────────────────────────────
              _SectionHeader(label: 'LOTES EN STOCK', theme: theme),
              if (_lotes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 16),
                  child: Text(
                    'Sin lotes en stock para este artículo.\n'
                    'Sincroniza el stock desde Configuración.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                )
              else
                ..._lotes.map((sl) {
                  final lineaDelLote = _lineas
                      .where((l) => l.codigoLote == sl.codigoLote)
                      .firstOrNull;
                  return _LoteStockRow(
                    lote: sl,
                    theme: theme,
                    lineaExistente: lineaDelLote,
                    onAnadir: () => _openLineaDialog(
                      preselLote: sl.codigoLote != 'SIN_LOTE'
                          ? sl.codigoLote
                          : null,
                      preselCad: sl.fechaCaducidad.year < 2090
                          ? sl.fechaCaducidad
                          : null,
                    ),
                    onEditar: lineaDelLote != null
                        ? () => _openLineaDialog(editing: lineaDelLote)
                        : null,
                  );
                }),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openLineaDialog(),
            icon: const Icon(Symbols.add),
            label: const Text('Añadir cantidad'),
          ),
    );
  }
}

// ── Sección header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final ThemeData theme;
  const _SectionHeader({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      color: cs.surfaceContainerHighest,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ── Fila de línea contada ─────────────────────────────────────────────────────

class _LineaRow extends StatelessWidget {
  final LineasInventarioLocalData linea;
  final ThemeData theme;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LineaRow({
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

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      title: Row(
        children: [
          if (isReal) ...[
            Icon(Symbols.tag, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(lote,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis),
            ),
          ] else
            Expanded(
              child: Text('Sin lote',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ),
          Text(
            _fmtNum.format(linea.stock),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: cs.primary,
            ),
          ),
          Text(' uds',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ],
      ),
      subtitle: cad != null && cad.year < 2090
          ? Text('Cad: ${_fmtDate.format(cad)}',
              style: const TextStyle(fontSize: 12))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Symbols.edit, size: 20),
            onPressed: onEdit,
            tooltip: 'Editar',
          ),
          IconButton(
            icon: Icon(Symbols.delete, size: 20, color: cs.error),
            onPressed: onDelete,
            tooltip: 'Eliminar',
          ),
        ],
      ),
    );
  }
}

// ── Fila de lote en stock ─────────────────────────────────────────────────────

class _LoteStockRow extends StatelessWidget {
  final StockLotesLocalData lote;
  final ThemeData theme;
  final LineasInventarioLocalData? lineaExistente;
  final VoidCallback onAnadir;
  final VoidCallback? onEditar;

  const _LoteStockRow({
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

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Icon(
            isReal ? Symbols.tag : Symbols.inventory_2,
            color: tieneApunte ? cs.primary : cs.onSurfaceVariant,
          ),
          if (tieneApunte)
            Icon(Symbols.check_circle, size: 12, color: cs.primary),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              isReal ? lote.codigoLote : 'Sin lote',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: tieneApunte ? cs.primary : cs.onSurface,
              ),
            ),
          ),
          if (tieneApunte) ...[
            const SizedBox(width: 8),
            Text(
              '→ ${_fmtNum.format(lineaExistente!.stock)} uds apuntados',
              style: TextStyle(fontSize: 11, color: cs.primary),
            ),
          ],
        ],
      ),
      subtitle: cad.year < 2090
          ? Text('Cad: ${_fmtDate.format(cad)}',
              style: const TextStyle(fontSize: 12))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('Stock actual',
                  style: TextStyle(
                      fontSize: 10, color: cs.onSurfaceVariant)),
              Text(
                _fmtNum.format(lote.stock),
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
            ],
          ),
          const SizedBox(width: 8),
          if (tieneApunte)
            IconButton(
              icon: Icon(Symbols.edit, size: 20, color: cs.primary),
              tooltip: 'Editar apunte de este lote',
              onPressed: onEditar,
            ),
          FilledButton.tonal(
            onPressed: onAnadir,
            style: FilledButton.styleFrom(
                minimumSize: const Size(64, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: const Text('Añadir'),
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
                  keyboardType: TextInputType.phone,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Código lote (opcional)',
                    prefixIcon: const Icon(Symbols.tag),
                    suffixIcon: _loteCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Symbols.close, size: 18),
                            onPressed: () =>
                                setState(() => _loteCtrl.clear()),
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
  final double? peso;
  final double? unicaj;
  final double? unipal;
  const ArticuloEditResult({this.cbarra, this.peso, this.unicaj, this.unipal});
}

class ArticuloEditDialog extends StatefulWidget {
  final ArticulosLocalData articulo;
  const ArticuloEditDialog({super.key, required this.articulo});
  @override
  State<ArticuloEditDialog> createState() => _ArticuloEditDialogState();
}

class _ArticuloEditDialogState extends State<ArticuloEditDialog> {
  late final TextEditingController _cbarraCtrl;
  late final TextEditingController _pesoCtrl;
  late final TextEditingController _unicajCtrl;
  late final TextEditingController _unipalCtrl;

  @override
  void initState() {
    super.initState();
    final a = widget.articulo;
    _cbarraCtrl = TextEditingController(text: a.codigoAlternativo1 ?? '');
    _pesoCtrl   = TextEditingController(text: a.peso   != null ? _fmtNum.format(a.peso)   : '');
    _unicajCtrl = TextEditingController(text: a.unicaj != null ? _fmtNum.format(a.unicaj) : '');
    _unipalCtrl = TextEditingController(text: a.unipal != null ? _fmtNum.format(a.unipal) : '');
  }

  @override
  void dispose() {
    _cbarraCtrl.dispose(); _pesoCtrl.dispose();
    _unicajCtrl.dispose(); _unipalCtrl.dispose();
    super.dispose();
  }

  void _selectAll(TextEditingController c) {
    c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
  }

  double? _parseNum(String s) =>
      double.tryParse(s.trim().replaceAll(',', '.').replaceAll('.', '.'));

  void _submit() {
    Navigator.pop(context, ArticuloEditResult(
      cbarra: _cbarraCtrl.text.trim().isEmpty ? null : _cbarraCtrl.text.trim(),
      peso:   _parseNum(_pesoCtrl.text),
      unicaj: _parseNum(_unicajCtrl.text),
      unipal: _parseNum(_unipalCtrl.text),
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
