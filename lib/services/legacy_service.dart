import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:dart_smb2/dart_smb2.dart';

import '../database/database.dart';
import '../database/tables.dart';
import 'config_service.dart';
import 'dbf_service.dart';

// Replica exacta del flujo PDA_Recibir_Inventario / PDA_Envia_Inventario
// del legacy GCPDA1.PRG, accediendo directamente a los DBF via SMB2.

const _kLegacyEmpresaId = 0;

class LegacyService {
  final AppDatabase _db;

  LegacyService(this._db);

  // ── Conexión SMB2 ──────────────────────────────────────────────────────────

  Future<Smb2Pool> _connect() async {
    // dart_smb2: https://pub.dev/packages/dart_smb2
    return await Smb2Pool.connect(
      host: ConfigService.legacySmbHost,
      share: ConfigService.legacySmbShare,
      user: ConfigService.legacySmbUser,
      password: ConfigService.legacySmbPass,
    );
  }

  String _path(String filename) {
    final sub = ConfigService.legacySmbPath.trim().replaceAll('\\', '/');
    return sub.isEmpty ? filename : '$sub/$filename';
  }

  Future<Uint8List> _readFile(Smb2Pool smb, String filename) async {
    return await smb.readFile(_path(filename));
  }

  Future<void> _writeFile(Smb2Pool smb, String filename, Uint8List data) async {
    await smb.writeFile(_path(filename), data);
  }

  // ── ID estable para artículos legacy (FNV-1a 32-bit) ──────────────────────

  static int _articuloId(String codigoArt) {
    final s = codigoArt.trim().toUpperCase();
    int hash = 0x811c9dc5;
    for (final b in s.codeUnits) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash == 0 ? 1 : hash;
  }

  static int _loteId(String codigoArt, String codigoAlm, String codigoLot) {
    return _articuloId('$codigoArt|$codigoAlm|$codigoLot');
  }

  // ── RECIBIR ────────────────────────────────────────────────────────────────
  // Replica PDA_Recibir_Inventario (GCPDA1.PRG línea 18406):
  //   - Copia ARTICULO.DBF + STOCKLOT.DBF del servidor
  //   - Construye tabla de trabajo local en Drift
  //   - INVEN1_ART = 9999999 (sentinel "no contado") → stock_inventariado = null

  Future<LegacySyncResult> recibir({LegacyFiltros? filtros}) async {
    final almacen = ConfigService.legacyAlmacen; // '1'..'5'

    final smb = await _connect();
    try {
      final articuloBytes = Uint8List.fromList(await _readFile(smb, 'ARTICULO.DBF'));
      final stocklotBytes = Uint8List.fromList(await _readFile(smb, 'STOCKLOT.DBF'));
      Uint8List? parametrBytes;
      try {
        parametrBytes = Uint8List.fromList(await _readFile(smb, 'PARAMETR.DBF'));
      } catch (_) {}

      final artDbf = DbfFile.open(articuloBytes);
      final stoDbf = DbfFile.open(stocklotBytes);

      // Extraer nombre empresa de PARAMETR.DBF
      String empresaNombre = '';
      if (parametrBytes != null) {
        try {
          final parDbf = DbfFile.open(parametrBytes);
          for (final (_, rec) in parDbf.records()) {
            final nombre = (rec['NOMBRE_PAR'] as String? ?? '').trim().toUpperCase();
            if (nombre == 'NOM_EMPR') {
              empresaNombre = (rec['VALOR_PAR'] as String? ?? '').trim();
              break;
            }
          }
        } catch (_) {}
      }

      // Limpiar datos legacy anteriores
      await _db.customStatement(
        'DELETE FROM articulos_local WHERE empresa_id = ?',
        [_kLegacyEmpresaId],
      );
      await _db.customStatement(
        'DELETE FROM almacenes_local WHERE empresa_id = ?',
        [_kLegacyEmpresaId],
      );
      await _db.customStatement(
        'DELETE FROM stock_lotes_local WHERE empresa_id = ?',
        [_kLegacyEmpresaId],
      );
      await _db.customStatement(
        'DELETE FROM stock_local WHERE empresa_id = ?',
        [_kLegacyEmpresaId],
      );

      // Crear almacenes 1-5 (legacy no tiene nombres reales)
      await _db.upsertAlmacenes([
        for (int i = 1; i <= 5; i++)
          AlmacenesLocalCompanion(
            almacenId: Value(i),
            empresaId: const Value(_kLegacyEmpresaId),
            nombre: Value('Almacén $i'),
          ),
      ]);

      // Leer PROVEEDO.DBF y FAMILIA.DBF para nombres reales
      final Map<String, String> mapPro = {};
      final Map<String, String> mapFam = {};
      try {
        final proDbf = DbfFile.open(Uint8List.fromList(await _readFile(smb, 'PROVEEDO.DBF')));
        final nameField = proDbf.fields.any((f) => f.name.toUpperCase() == 'NOMBRE_PRO')
            ? 'NOMBRE_PRO'
            : proDbf.fields.any((f) => f.name.toUpperCase() == 'RAZSOC_PRO')
                ? 'RAZSOC_PRO'
                : proDbf.fields.any((f) => f.name.toUpperCase() == 'COMERCI_PRO')
                    ? 'COMERCI_PRO'
                    : '';
        if (nameField.isNotEmpty) {
          for (final (_, rec) in proDbf.records()) {
            final cod  = (rec['CODIGO_PRO'] as String? ?? '').trim();
            final name = (rec[nameField]   as String? ?? '').trim();
            if (cod.isNotEmpty && name.isNotEmpty) mapPro[cod] = name;
          }
        }
      } catch (_) {}
      try {
        final famDbf = DbfFile.open(Uint8List.fromList(await _readFile(smb, 'FAMILIA.DBF')));
        final nameField = famDbf.fields.any((f) => f.name.toUpperCase() == 'NOMBRE_FAM')
            ? 'NOMBRE_FAM'
            : famDbf.fields.any((f) => f.name.toUpperCase() == 'DESCRI_FAM')
                ? 'DESCRI_FAM'
                : '';
        if (nameField.isNotEmpty) {
          for (final (_, rec) in famDbf.records()) {
            final cod  = (rec['CODIGO_FAM'] as String? ?? '').trim();
            final name = (rec[nameField]   as String? ?? '').trim();
            if (cod.isNotEmpty && name.isNotEmpty) mapFam[cod] = name;
          }
        }
      } catch (_) {}

      // Leer USUARIO.DBF para lista de usuarios
      final List<String> usuarios = [];
      try {
        final usuDbf = DbfFile.open(Uint8List.fromList(await _readFile(smb, 'USUARIO.DBF')));
        final codeField = usuDbf.fields.any((f) => f.name.toUpperCase() == 'CODIGO_USU')
            ? 'CODIGO_USU'
            : usuDbf.fields.any((f) => f.name.toUpperCase() == 'USUARIO')
                ? 'USUARIO'
                : usuDbf.fields.any((f) => f.name.toUpperCase() == 'CODIGO')
                    ? 'CODIGO'
                    : '';
        if (codeField.isNotEmpty) {
          for (final (_, rec) in usuDbf.records()) {
            final cod = (rec[codeField] as String? ?? '').trim();
            if (cod.isNotEmpty) usuarios.add(cod);
          }
        }
      } catch (_) {}

      // Insertar artículos
      int tiposValidos = 0;
      final artRows = <ArticulosLocalCompanion>[];
      for (final (_, rec) in artDbf.records()) {
        final codigo = (rec['CODIGO_ART'] as String).trim();
        if (codigo.isEmpty) continue;
        final exportArt = (rec['EXPORT_ART'] as String? ?? '').trim().toUpperCase();
        if (exportArt == 'N') continue;

        final codPro = (rec['CODIGO_PRO'] as String? ?? '').trim();
        final codFam = (rec['CODIGO_FAM'] as String? ?? '').trim();

        // Aplicar filtros
        if (filtros != null) {
          final provNombre = (mapPro[codPro] ?? codPro).trim();
          final famNombre  = (mapFam[codFam] ?? codFam).trim();
          if (filtros.proveedor != null && provNombre != filtros.proveedor) continue;
          if (filtros.familia   != null && famNombre  != filtros.familia)   continue;
          if (filtros.tipos.isNotEmpty) {
            final tipoArt = (rec['TIPO_ART'] as String? ?? '').trim().toUpperCase();
            if (!filtros.tipos.contains(tipoArt)) continue;
          }
        }

        artRows.add(ArticulosLocalCompanion(
          articuloId: Value(_articuloId(codigo)),
          empresaId: const Value(_kLegacyEmpresaId),
          identificacion: Value(codigo),
          descripcion1: Value((rec['NOMBRE_ART'] as String? ?? '').trim()),
          codigoAlternativo1: Value((rec['CBARRA_ART'] as String? ?? '').trim()),
          ubicacion: Value((rec['UBICAC_ART'] as String? ?? '').trim().nullIfEmpty()),
          familiaId: const Value(0),
          familiaNombre: Value(mapFam[codFam] ?? codFam),
          proveedorId: const Value(0),
          proveedorNombre: Value(mapPro[codPro] ?? codPro),
          peso:   Value((rec['PESO_ART']   as num?)?.toDouble()),
          unicaj: Value((rec['UNICAJ_ART'] as num?)?.toDouble()),
          unipal: Value((rec['UNIPAL_ART'] as num?)?.toDouble()),
          ultimaSync: Value(DateTime.now()),
        ));
        tiposValidos++;
      }
      await _db.upsertArticulos(artRows);

      // Snapshot de STOCK#_ART → StockLocal (para calcular diff en enviar)
      final almInt = int.tryParse(almacen) ?? 1;
      final stockField = 'STOCK${almInt}_ART';
      final stockRows = <StockLocalCompanion>[];
      for (final (_, rec) in artDbf.records()) {
        final codigo = (rec['CODIGO_ART'] as String).trim();
        if (codigo.isEmpty) continue;
        final snap = (rec[stockField] as num? ?? 0).toDouble();
        stockRows.add(StockLocalCompanion(
          empresaId: const Value(_kLegacyEmpresaId),
          almacenId: Value(almInt),
          articuloId: Value(_articuloId(codigo)),
          unidades: Value(snap),
          precioCoste: Value((rec['PCOSTE_ART'] as num? ?? 0).toDouble()),
          fechaStock: Value(DateTime.now()),
          ultimaSync: Value(DateTime.now()),
        ));
      }
      await _db.upsertStock(stockRows);

      // Insertar STOCKLOT del almacén seleccionado
      final lotRows = <StockLotesLocalCompanion>[];
      for (final (_, rec) in stoDbf.records()) {
        final codigoAlm = (rec['CODIGO_ALM'] as String? ?? '').trim();
        if (codigoAlm != almacen) continue;

        final codigoArt = (rec['CODIGO_ART'] as String? ?? '').trim();
        final codigoLot = (rec['CODIGO_LOT'] as String? ?? '').trim();
        final unidad = (rec['UNIDAD_LOT'] as num? ?? 0).toDouble();
        final fecCad = rec['FECCAD_LOT'] as DateTime?;

        lotRows.add(StockLotesLocalCompanion(
          stockLoteId: Value(_loteId(codigoArt, codigoAlm, codigoLot)),
          empresaId: const Value(_kLegacyEmpresaId),
          articuloId: Value(_articuloId(codigoArt)),
          almacenId: Value(almInt),
          codigoLote: Value(codigoLot.isEmpty ? 'SIN_LOTE' : codigoLot),
          fechaCaducidad: Value(fecCad ?? DateTime(2099)),
          stock: Value(unidad),
          ultimaSync: Value(DateTime.now()),
        ));
      }
      await _db.upsertStockLotes(lotRows);

      return LegacySyncResult(
        articulos: tiposValidos,
        lotes: lotRows.length,
        empresaNombre: empresaNombre,
        usuarios: usuarios,
      );
    } finally {
      await smb.disconnect();
    }
  }

  // ── ENVIAR ─────────────────────────────────────────────────────────────────
  // Replica PDA_Envia_Inventario (GCPDA1.PRG línea 18205):
  //   - Abre ARTICULO.DBF + STOCKLOT.DBF + E_S_Alma.DBF + PARAMETR.DBF
  //   - Por cada artículo contado: aplica diff a STOCK#_ART
  //   - Por cada lote: aplica diff a STOCKLOT.UNIDAD_LOT
  //   - Graba 2 registros en E_S_Alma: "INVENTARIO ANTES" (S) + "INVENTARIO OK" (E)
  //   - Actualiza contador E_S_EMPR en PARAMETR.DBF

  Future<LegacyEnvioResult> enviar(
    CabecerasInventarioLocalData cab,
    List<LineasInventarioLocalData> lineas,
  ) async {
    if (lineas.isEmpty) throw LegacyException('Sin líneas contadas');

    final almacen = ConfigService.legacyAlmacen;
    final almInt = int.tryParse(almacen) ?? 1;
    final stockField = 'STOCK${almInt}_ART';
    final usuario = ConfigService.usuario.isNotEmpty ? ConfigService.usuario : 'INVENTARIO';

    // Fecha/hora para FECMOD_E_S (formato Harbour: DD/MM/YYYY HH:MM)
    final now = DateTime.now();
    final p2 = (int v) => v.toString().padLeft(2, '0');
    final fechaMod = '${p2(now.day)}/${p2(now.month)}/${now.year} ${p2(now.hour)}:${p2(now.minute)}';
    final fechaInv = cab.fechaOperacion;

    // Agrupar líneas por artículo
    final Map<int, List<LineasInventarioLocalData>> byArticulo = {};
    for (final l in lineas) {
      byArticulo.putIfAbsent(l.articuloId, () => []).add(l);
    }

    final smb = await _connect();
    try {
      // Leer archivos obligatorios del servidor
      final artDbf = DbfFile.open(await _readFile(smb, 'ARTICULO.DBF'));
      final stoDbf = DbfFile.open(await _readFile(smb, 'STOCKLOT.DBF'));

      // E_S_Alma.DBF y PARAMETR.DBF opcionales (si fallan no bloqueamos el envío)
      DbfFile? esDbf;
      DbfFile? parDbf;
      try { esDbf  = DbfFile.open(await _readFile(smb, 'E_S_Alma.DBF')); } catch (_) {}
      try { parDbf = DbfFile.open(await _readFile(smb, 'PARAMETR.DBF')); } catch (_) {}

      // Leer contador E_S_EMPR desde PARAMETR
      int esEmpr = 0;
      int parEmprIdx = -1;
      if (parDbf != null) {
        for (final (idx, rec) in parDbf.records()) {
          if ((rec['NOMBRE_PAR'] as String? ?? '').trim().toUpperCase() == 'E_S_EMPR') {
            esEmpr = int.tryParse((rec['VALOR_PAR'] as String? ?? '').trim()) ?? 0;
            parEmprIdx = idx;
            break;
          }
        }
      }

      int modificados = 0;
      int inventariados = 0;
      int movimientos = 0;

      for (final entry in byArticulo.entries) {
        final articuloId = entry.key;
        final artLineas = entry.value;

        final artLocal = await _db.getArticuloById(_kLegacyEmpresaId, articuloId);
        if (artLocal == null) continue;

        final codigoArt = artLocal.identificacion.trim();

        // Totales contados y snapshot
        final newTotal = artLineas.fold<double>(0, (s, l) => s + l.stock);
        final oldRows  = await _db.getStock(_kLegacyEmpresaId, articuloId);
        final oldStock = oldRows.isEmpty ? 0.0 : oldRows.first.unidades;
        final diff     = newTotal - oldStock;

        // Actualizar ARTICULO.DBF: STOCK#_ART += diff
        final artIdx = artDbf.findByKey({'CODIGO_ART': codigoArt});
        double precioCoste = 0.0;
        if (artIdx >= 0) {
          precioCoste = artDbf.getNum(artIdx, 'PCOSTE_ART');
          final currentStock = artDbf.getNum(artIdx, stockField);
          artDbf.setFields(artIdx, {stockField: currentStock + diff});
          inventariados++;
        }

        final hasLotes = artLineas.any((l) => l.codigoLote != null && l.codigoLote != 'SIN_LOTE');

        if (!hasLotes) {
          // Sin trazabilidad: escribir movimiento global en E_S_Alma
          if (esDbf != null) {
            esEmpr++;
            esDbf.appendRecord(_esRecord(
              codigoEs: esEmpr, codigoArt: codigoArt, tipo: 'S',
              descri: 'INVENTARIO ANTES', origen: almInt, destin: 0,
              unidad: oldStock, precio: precioCoste, fecha: fechaInv,
              lote: '', fechaMod: fechaMod, usuario: usuario,
            ));
            esEmpr++;
            esDbf.appendRecord(_esRecord(
              codigoEs: esEmpr, codigoArt: codigoArt, tipo: 'E',
              descri: 'INVENTARIO OK', origen: 0, destin: almInt,
              unidad: newTotal, precio: precioCoste, fecha: fechaInv,
              lote: '', fechaMod: fechaMod, usuario: usuario,
            ));
            movimientos += 2;
          }
        } else {
          // Con trazabilidad: actualizar STOCKLOT + movimiento por lote
          final loteRows = await _db.getStockLotes(_kLegacyEmpresaId, articuloId);

          for (final linea in artLineas) {
            final loteInterno = (linea.codigoLote ?? '').trim();
            // SIN_LOTE interno → 'S/LOTE' en STOCKLOT.DBF del servidor
            final lote = (loteInterno.isEmpty || loteInterno == 'SIN_LOTE')
                ? 'S/LOTE'
                : loteInterno;

            final newLoteStock = linea.stock;
            // Buscar snapshot tanto por código interno como externo
            final loteSnap = loteRows
                .where((r) => r.codigoLote == loteInterno || r.codigoLote == lote)
                .fold<double>(0, (s, r) => s + r.stock);
            final loteDiff = newLoteStock - loteSnap;

            final stoIdx = stoDbf.findByKey({
              'CODIGO_ART': codigoArt,
              'CODIGO_ALM': almacen,
              'CODIGO_LOT': lote,
            });

            if (stoIdx >= 0) {
              final currentUnidad = stoDbf.getNum(stoIdx, 'UNIDAD_LOT');
              stoDbf.setFields(stoIdx, {
                'UNIDAD_LOT': currentUnidad + loteDiff,
                'UNIANT_LOT': currentUnidad,
              });
            } else {
              final cadSnap = loteRows.where((r) => r.codigoLote == lote).firstOrNull;
              final fecCad = linea.fechaCaducidad ?? cadSnap?.fechaCaducidad ?? DateTime(2099);
              stoDbf.appendRecord({
                'CODIGO_ART': codigoArt,
                'CODIGO_ALM': almacen,
                'CODIGO_LOT': lote,
                'FECALT_LOT': DateTime.now(),
                'FECCAD_LOT': fecCad,
                'UNIDAD_LOT': newLoteStock,
                'UNIANT_LOT': 0.0,
                'CODIGO_PAL': '',
                'CODIGO_UBI': '',
              });
            }

            if (esDbf != null) {
              esEmpr++;
              esDbf.appendRecord(_esRecord(
                codigoEs: esEmpr, codigoArt: codigoArt, tipo: 'S',
                descri: 'INVENTARIO ANTES', origen: almInt, destin: 0,
                unidad: loteSnap, precio: precioCoste, fecha: fechaInv,
                lote: lote, fechaMod: fechaMod, usuario: usuario,
              ));
              esEmpr++;
              esDbf.appendRecord(_esRecord(
                codigoEs: esEmpr, codigoArt: codigoArt, tipo: 'E',
                descri: 'INVENTARIO OK', origen: 0, destin: almInt,
                unidad: newLoteStock, precio: precioCoste, fecha: fechaInv,
                lote: lote, fechaMod: fechaMod, usuario: usuario,
              ));
              movimientos += 2;
            }
          }
        }
        modificados++;
      }

      // Actualizar contador E_S_EMPR en PARAMETR
      if (parDbf != null && parEmprIdx >= 0 && movimientos > 0) {
        parDbf.setFields(parEmprIdx, {'VALOR_PAR': esEmpr.toString()});
      }

      // Escribir archivos al servidor
      await _writeFile(smb, 'ARTICULO.DBF', artDbf.toBytes());
      await _writeFile(smb, 'STOCKLOT.DBF', stoDbf.toBytes());
      if (esDbf  != null && movimientos > 0) await _writeFile(smb, 'E_S_Alma.DBF', esDbf.toBytes());
      if (parDbf != null && movimientos > 0) await _writeFile(smb, 'PARAMETR.DBF', parDbf.toBytes());

      return LegacyEnvioResult(
        modificados: modificados,
        inventariados: inventariados,
        movimientos: movimientos,
      );
    } finally {
      await smb.disconnect();
    }
  }

  // ── GUARDAR CAMPOS ARTÍCULO ────────────────────────────────────────────────
  // Escribe CBARRA_ART, PESO_ART, UNICAJ_ART, UNIPAL_ART en ARTICULO.DBF.

  Future<void> saveArticuloFields(
    String codigoArt, {
    String? cbarra,
    String? ubicacion,
    double? peso,
    double? unicaj,
    double? unipal,
  }) async {
    final smb = await _connect();
    try {
      final artDbf = DbfFile.open(await _readFile(smb, 'ARTICULO.DBF'));
      final idx = artDbf.findByKey({'CODIGO_ART': codigoArt});
      if (idx < 0) throw LegacyException('Artículo no encontrado: $codigoArt');
      final updates = <String, dynamic>{};
      if (cbarra    != null) updates['CBARRA_ART']  = cbarra;
      if (ubicacion != null) updates['UBICAC_ART']  = ubicacion;
      if (peso      != null) updates['PESO_ART']    = peso;
      if (unicaj    != null) updates['UNICAJ_ART']  = unicaj;
      if (unipal    != null) updates['UNIPAL_ART']  = unipal;
      if (updates.isNotEmpty) artDbf.setFields(idx, updates);
      await _writeFile(smb, 'ARTICULO.DBF', artDbf.toBytes());
    } finally {
      await smb.disconnect();
    }
  }

  static Map<String, dynamic> _esRecord({
    required int codigoEs,
    required String codigoArt,
    required String tipo,
    required String descri,
    required int origen,
    required int destin,
    required double unidad,
    required double precio,
    required DateTime fecha,
    required String lote,
    required String fechaMod,
    required String usuario,
  }) =>
      {
        'CODIGO_E_S': codigoEs.toDouble(),
        'CODIGO_ART': codigoArt,
        'TIPO_E_S':   tipo,
        'DESCRI_E_S': descri,
        'ORIGEN_E_S': origen.toDouble(),
        'DESTIN_E_S': destin.toDouble(),
        'CODIGO_TMO': 'CA',
        'UNIDAD_E_S': unidad,
        'PRECIO_E_S': precio,
        'FECHA_E_S':  fecha,
        'CODIGO_CLI': 'INVENTARIO',
        'CLOTE_E_S':  lote,
        'FECMOD_E_S': fechaMod,
        'USUMOD_E_S': usuario,
      };
}

class LegacySyncResult {
  final int articulos;
  final int lotes;
  final String empresaNombre;
  final List<String> usuarios;
  const LegacySyncResult({
    required this.articulos,
    required this.lotes,
    this.empresaNombre = '',
    this.usuarios = const [],
  });
}

class LegacyEnvioResult {
  final int modificados;
  final int inventariados;
  final int movimientos;
  const LegacyEnvioResult({required this.modificados, required this.inventariados, this.movimientos = 0});
}

class LegacyException implements Exception {
  final String message;
  const LegacyException(this.message);
  @override
  String toString() => message;
}

class LegacyFiltros {
  final String? proveedor;
  final String? familia;
  final Set<String> tipos; // vacío = sin filtro de tipo
  const LegacyFiltros({this.proveedor, this.familia, this.tipos = const {}});
}

extension _StringX on String {
  String? nullIfEmpty() => isEmpty ? null : this;
}
