import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:dart_smb2/dart_smb2.dart';

import '../database/database.dart';
import '../database/tables.dart';
import 'config_service.dart';
import 'dbf_service.dart';
import 'log_service.dart';
import 'ntx_service.dart';

// Replica exacta del flujo PDA_Recibir_Inventario / PDA_Envia_Inventario
// del legacy GCPDA1.PRG, accediendo directamente a los DBF via SMB2.

const _kLegacyEmpresaId = 0;

class LegacyService {
  final AppDatabase _db;

  LegacyService(this._db);

  // ── Conexión SMB2 ──────────────────────────────────────────────────────────

  /// Timeout por operación SMB. enviar() lo amplía a 5 min con muchas líneas.
  /// Sin esto, una operación SMB que se atasca deja el envío "pensando"
  /// indefinidamente y sin liberar los archivos renombrados.
  Duration _smbTimeout = const Duration(minutes: 2);

  Future<Smb2Pool> _connect() async {
    // dart_smb2: https://pub.dev/packages/dart_smb2
    return await Smb2Pool.connect(
      host: ConfigService.legacySmbHost,
      share: ConfigService.legacySmbShare,
      user: ConfigService.legacySmbUser,
      password: ConfigService.legacySmbPass,
    ).timeout(const Duration(seconds: 40));
  }

  Future<void> _safeDisconnect(Smb2Pool smb) async {
    try {
      await smb.disconnect().timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  String _path(String filename) {
    final sub = ConfigService.legacySmbPath.trim().replaceAll('\\', '/');
    return sub.isEmpty ? filename : '$sub/$filename';
  }

  Future<Uint8List> _readFile(Smb2Pool smb, String filename) async {
    return await smb.readFile(_path(filename)).timeout(_smbTimeout);
  }

  Future<void> _writeFile(Smb2Pool smb, String filename, Uint8List data) async {
    await smb.writeFile(_path(filename), data).timeout(_smbTimeout);
  }

  /// Sube solo lo cambiado de un DBF: registros modificados, el bloque de
  /// registros añadidos al final y el header (fecha + contador). Evita
  /// reescribir archivos grandes enteros (E_S_ALMA crece sin límite).
  Future<void> _writeDbfRanges(Smb2Pool smb, String filename, DbfFile dbf) async {
    if (!dbf.hasChanges) return;
    final path = _path(filename);
    for (final i in dbf.dirtyRecords) {
      final r = dbf.recordRegion(i);
      await smb
          .writeFileRange(path, r.bytes, offset: r.offset)
          .timeout(_smbTimeout);
    }
    if (dbf.hasAppends) {
      final a = dbf.appendedRegion();
      await smb
          .writeFileRange(path, a.bytes, offset: a.offset)
          .timeout(_smbTimeout);
    }
    await smb
        .writeFileRange(path, dbf.headerStampBytes(), offset: 1)
        .timeout(_smbTimeout);
  }

  Future<bool> _exists(Smb2Pool smb, String filename) async {
    try {
      return await smb.exists(_path(filename)).timeout(_smbTimeout);
    } catch (_) {
      return false;
    }
  }

  // ── Acceso exclusivo a los DBF del servidor ────────────────────────────────
  // El ERP GC abre los DBF en modo compartido con bloqueos de registro; esta
  // app reescribe archivos completos, así que necesita exclusividad. Renombrar
  // el archivo lo garantiza: Windows rechaza el rename si cualquier puesto lo
  // tiene abierto, y mientras está renombrado ningún puesto puede abrirlo.

  static const _lockSuffix = '.PDA';

  String _lockedName(List<String> acquired, String filename) =>
      acquired.contains(filename) ? '$filename$_lockSuffix' : filename;

  /// Renombra [files] a su nombre temporal. Si alguno falla, restaura los ya
  /// renombrados y lanza [LegacyException] con un diagnóstico claro.
  Future<List<String>> _acquireExclusive(Smb2Pool smb, List<String> files) async {
    final acquired = <String>[];
    for (final f in files) {
      try {
        await smb
            .rename(_path(f), _path('$f$_lockSuffix'))
            .timeout(_smbTimeout);
        acquired.add(f);
      } catch (e) {
        await _releaseExclusive(smb, acquired);
        final original = await _exists(smb, f);
        final temporal = await _exists(smb, '$f$_lockSuffix');
        if (!original && temporal) {
          throw LegacyException(
              'Hay un envío anterior interrumpido: existe "$f$_lockSuffix" en el '
              'servidor. Comprueba su contenido, renómbralo a "$f" y regenera '
              'los índices desde GC antes de reintentar.');
        }
        if (!original) {
          throw LegacyException('No existe "$f" en el servidor.');
        }
        throw LegacyException(
            'No se pudo obtener acceso exclusivo a "$f": hay puestos usando GC. '
            'Pide que salgan de la aplicación y reintenta.');
      }
    }
    return acquired;
  }

  /// Restaura los nombres originales. Devuelve los archivos que no se
  /// pudieron restaurar (lista vacía = todo bien).
  Future<List<String>> _releaseExclusive(Smb2Pool smb, List<String> acquired) async {
    final pendientes = <String>[];
    for (final f in acquired.reversed) {
      try {
        await smb
            .rename(_path('$f$_lockSuffix'), _path(f))
            .timeout(_smbTimeout);
      } catch (_) {
        pendientes.add(f);
      }
    }
    return pendientes;
  }

  /// Nombre remoto del archivo de índice: respeta el casing existente en el
  /// servidor (relevante en NAS samba case-sensitive); si no existe aún, se
  /// crea con el nombre canónico en mayúsculas.
  Future<String> _ntxRemoteName(Smb2Pool smb, String canonical) async {
    if (await _exists(smb, canonical)) return canonical;
    final lower = canonical.toLowerCase();
    if (await _exists(smb, lower)) return lower;
    return canonical;
  }

  /// Regenera los índices de [dbfKey] que EXISTAN en el servidor, usando la
  /// expresión de clave leída del header de cada NTX real (cada instalación
  /// de GC puede indexar distinto). Nunca crea índices nuevos, y aborta si la
  /// clave generada no encaja con la del servidor.
  Future<void> _regenerarIndices(Smb2Pool smb, String dbfKey, DbfFile dbf,
      Map<String, Uint8List> out, void Function(String) fase) async {
    for (final def in ntxIndexesByDbf[dbfKey]!) {
      final nombre = await _ntxRemoteName(smb, def.ntxFile);
      Uint8List head;
      try {
        head = await smb
            .readFileRange(_path(nombre), offset: 0, length: 1024)
            .timeout(_smbTimeout);
      } catch (_) {
        fase('índice ${def.ntxFile} no existe en el servidor: no se genera');
        continue;
      }
      final info = NtxHeaderInfo.parse(head);
      if (info.unique != 0) {
        throw LegacyException(
            'El índice $nombre es UNIQUE y no está soportado. Envío abortado.');
      }
      final expr = info.expression.isNotEmpty ? info.expression : def.expression;
      final built = NtxBuilder.build(dbf, expr);
      final builtKeySize =
          ByteData.sublistView(built).getUint16(14, Endian.little);
      if (info.keySize != 0 && builtKeySize != info.keySize) {
        throw LegacyException(
            'Índice $nombre: clave generada de ${builtKeySize}B pero el servidor '
            'usa ${info.keySize}B (expresión "$expr"). Abortado para no '
            'corromper índices.');
      }
      out[nombre] = built;
      fase('índice $nombre regenerado con expresión "$expr"');
    }
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

  /// Números sin decimales de relleno para los mensajes de auditoría.
  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3);

  // ── CLASES DE ARTÍCULO ────────────────────────────────────────────────────
  // Lee CLASEART.DBF y devuelve {nivel (1-5) → [(código, nombre), ...]}
  // Usa el campo NIVEL_CLA para agrupar por nivel.

  Future<Map<int, List<(String, String)>>> readClaseOptions() async {
    final smb = await _connect();
    try {
      final bytes = Uint8List.fromList(await _readFile(smb, 'CLASEART.DBF'));
      final dbf   = DbfFile.open(bytes);
      final fieldNames = dbf.fields.map((f) => f.name.toUpperCase()).toSet();

      final hasNivel  = fieldNames.contains('NIVEL_CLA');
      final nameField = fieldNames.contains('NOMBRE_CLA') ? 'NOMBRE_CLA'
          : fieldNames.contains('DESCRI_CLA') ? 'DESCRI_CLA'
          : fieldNames.contains('NOMBRE')     ? 'NOMBRE'
          : '';
      if (nameField.isEmpty) return {};

      final result = <int, List<(String, String)>>{};
      for (final (_, rec) in dbf.records()) {
        final codigo = (rec['CODIGO_CLA'] as String? ?? '').trim();
        final nombre = (rec[nameField]   as String? ?? '').trim();
        if (codigo.isEmpty) continue;
        final label = nombre.isEmpty ? codigo : nombre;

        if (hasNivel) {
          final raw    = rec['NIVEL_CLA'];
          final nivel  = raw is num ? (raw as num).toInt()
              : int.tryParse((raw as String? ?? '').trim()) ?? 0;
          if (nivel < 1 || nivel > 5) continue;
          result.putIfAbsent(nivel, () => []).add((codigo, label));
        } else {
          result.putIfAbsent(1, () => []).add((codigo, label));
        }
      }
      return result;
    } catch (_) {
      return {};
    } finally {
      await _safeDisconnect(smb);
    }
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

      // Leer CLASEART.DBF para cachear código→nombre
      final Map<String, String> mapClase = {};
      try {
        final claseDbf = DbfFile.open(Uint8List.fromList(await _readFile(smb, 'CLASEART.DBF')));
        final nameField = claseDbf.fields.any((f) => f.name.toUpperCase() == 'NOMBRE_CLA')
            ? 'NOMBRE_CLA'
            : claseDbf.fields.any((f) => f.name.toUpperCase() == 'DESCRI_CLA')
                ? 'DESCRI_CLA' : '';
        if (nameField.isNotEmpty) {
          for (final (_, rec) in claseDbf.records()) {
            final cod  = (rec['CODIGO_CLA'] as String? ?? '').trim();
            final name = (rec[nameField]   as String? ?? '').trim();
            if (cod.isNotEmpty && name.isNotEmpty) mapClase[cod] = name;
          }
        }
      } catch (_) {}
      await ConfigService.saveClaseNombres(mapClase);

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
          if (filtros.clases.isNotEmpty) {
            bool pasaClase = true;
            for (final entry in filtros.clases.entries) {
              final codClase = (rec['CODIG${entry.key}_CLA'] as String? ?? '').trim();
              if (codClase != entry.value) { pasaClase = false; break; }
            }
            if (!pasaClase) continue;
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
          clase1: Value((rec['CODIG1_CLA'] as String? ?? '').trim().nullIfEmpty()),
          clase2: Value((rec['CODIG2_CLA'] as String? ?? '').trim().nullIfEmpty()),
          clase3: Value((rec['CODIG3_CLA'] as String? ?? '').trim().nullIfEmpty()),
          clase4: Value((rec['CODIG4_CLA'] as String? ?? '').trim().nullIfEmpty()),
          clase5: Value((rec['CODIG5_CLA'] as String? ?? '').trim().nullIfEmpty()),
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
      await _safeDisconnect(smb);
    }
  }

  // ── ENVIAR ─────────────────────────────────────────────────────────────────
  // Replica PDA_Envia_Inventario (GCPDA1.PRG línea 18205):
  //   - Abre ARTICULO.DBF + STOCKLOT.DBF + E_S_ALMA.DBF + PARAMETR.DBF
  //   - Por cada artículo contado: aplica diff a STOCK#_ART
  //   - Por cada lote: aplica diff a STOCKLOT.UNIDAD_LOT
  //   - Graba 2 registros en E_S_ALMA: "INVENTARIO ANTES" (S) + "INVENTARIO OK" (E)
  //   - Actualiza contador E_S_EMPR en PARAMETR.DBF

  Future<LegacyEnvioResult> enviar(
    CabecerasInventarioLocalData cab,
    List<LineasInventarioLocalData> lineas,
  ) async {
    if (lineas.isEmpty) throw LegacyException('Sin líneas contadas');

    // Timeout por operación: 2 min, ampliado a 5 con muchas líneas.
    _smbTimeout = Duration(minutes: lineas.length > 200 ? 5 : 2);

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
    var acquired = const <String>[];
    var envioCompletado = false;
    // Diagnóstico: cada fase queda en el log de incidencias con su tiempo.
    final sw = Stopwatch()..start();
    void fase(String msg) {
      LogService.registrar(
          'ENVÍO [${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] $msg');
    }
    try {
      // Acceso exclusivo mientras dura el envío: si algún puesto tiene los
      // archivos abiertos, el rename falla y abortamos sin tocar nada.
      // PARAMETR.DBF no se bloquea: los puestos lo tienen abierto toda la
      // sesión (tabla de parámetros) y aquí solo se actualiza por rango el
      // contador E_S_EMPR, que nadie más toca sin tener E_S_ALMA abierto.
      final lockFiles = ['ARTICULO.DBF', 'STOCKLOT.DBF'];
      if (await _exists(smb, 'E_S_ALMA.DBF')) lockFiles.add('E_S_ALMA.DBF');
      acquired = await _acquireExclusive(smb, lockFiles);

      // Leer archivos obligatorios del servidor (ya con nombre temporal)
      final artDbf = DbfFile.open(await _readFile(smb, _lockedName(acquired, 'ARTICULO.DBF')));
      final stoDbf = DbfFile.open(await _readFile(smb, _lockedName(acquired, 'STOCKLOT.DBF')));

      // E_S_ALMA.DBF y PARAMETR.DBF opcionales (si fallan no bloqueamos el envío)
      DbfFile? esDbf;
      DbfFile? parDbf;
      try { esDbf  = DbfFile.open(await _readFile(smb, _lockedName(acquired, 'E_S_ALMA.DBF'))); } catch (_) {}
      try { parDbf = DbfFile.open(await _readFile(smb, 'PARAMETR.DBF')); } catch (_) {}
      fase('leídos ARTICULO (${artDbf.numRecords}), STOCKLOT (${stoDbf.numRecords}), '
          'E_S_ALMA (${esDbf?.numRecords ?? 'NO DISPONIBLE'})');

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
      // FECCAD_LOT forma parte de las claves de STOCKLO2/STOCKLO4: si cambia
      // en un registro existente hay que regenerar los índices de STOCKLOT
      // aunque no haya appends.
      bool stocklotClaveCambiada = false;

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
          LogService.auditar('ENVÍO art $codigoArt: $stockField '
              '${_fmtNum(currentStock)}→${_fmtNum(currentStock + diff)}');
        } else {
          LogService.auditar(
              'ENVÍO art $codigoArt: NO ENCONTRADO en ARTICULO.DBF');
        }

        // Por cada línea contada: upsert en STOCKLOT + par de movimientos E/S.
        // Los artículos sin trazabilidad también guardan su stock en STOCKLOT,
        // bajo el lote 'S/LOTE' (igual que Act_Stock_Lote en GC): si no se
        // actualiza, la tabla de stock del ERP no refleja el inventario aunque
        // STOCK#_ART sí cambie.
        final loteRows = await _db.getStockLotes(_kLegacyEmpresaId, articuloId);

        for (final linea in artLineas) {
          final loteInterno = (linea.codigoLote ?? '').trim();
          final esSinLote = loteInterno.isEmpty || loteInterno == 'SIN_LOTE';
          // SIN_LOTE interno → 'S/LOTE' en STOCKLOT.DBF del servidor
          final lote = esSinLote ? 'S/LOTE' : loteInterno;

          final newLoteStock = linea.stock;
          // Snapshot local del lote (busca por código interno y externo). Para
          // una línea sin lote de un artículo sin lotes cacheados, el snapshot
          // es el stock del artículo.
          final snapRows = loteRows
              .where((r) => r.codigoLote == loteInterno || r.codigoLote == lote)
              .toList();
          final loteSnap = snapRows.isEmpty && esSinLote
              ? oldStock
              : snapRows.fold<double>(0, (s, r) => s + r.stock);
          final loteDiff = newLoteStock - loteSnap;

          final stoIdx = stoDbf.findByKey({
            'CODIGO_ART': codigoArt,
            'CODIGO_ALM': almacen,
            'CODIGO_LOT': lote,
          });

          String accion;
          if (stoIdx >= 0) {
            final currentUnidad = stoDbf.getNum(stoIdx, 'UNIDAD_LOT');
            final updates = <String, dynamic>{
              'UNIDAD_LOT': currentUnidad + loteDiff,
              // Como PDA_Envia_Inventario: UNIANT_LOT = valor contado en tablet
              'UNIANT_LOT': newLoteStock,
            };
            final fecCad =
                linea.fechaCaducidad ?? snapRows.firstOrNull?.fechaCaducidad;
            if (fecCad != null) {
              // Solo escribir si de verdad cambia: evita regenerar los
              // índices de STOCKLOT (FECCAD es clave) sin necesidad.
              final actual = String.fromCharCodes(
                      stoDbf.fieldBytes(stoIdx, 'FECCAD_LOT') ?? [])
                  .trim();
              final nuevo = '${fecCad.year.toString().padLeft(4, '0')}'
                  '${fecCad.month.toString().padLeft(2, '0')}'
                  '${fecCad.day.toString().padLeft(2, '0')}';
              if (actual != nuevo) {
                updates['FECCAD_LOT'] = fecCad;
                stocklotClaveCambiada = true;
              }
            }
            stoDbf.setFields(stoIdx, updates);
            accion = 'STOCKLOT ${_fmtNum(currentUnidad)}→'
                '${_fmtNum(currentUnidad + loteDiff)}';
          } else {
            final fecCad = linea.fechaCaducidad ??
                snapRows.firstOrNull?.fechaCaducidad ?? DateTime(2099);
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
            accion = 'STOCKLOT creado con ${_fmtNum(newLoteStock)}';
          }

          LogService.auditar('ENVÍO art $codigoArt'
              '${esSinLote ? '' : ' lote $lote'} alm $almacen: '
              'antes ${_fmtNum(loteSnap)}, contado ${_fmtNum(newLoteStock)} '
              '→ $accion');

          if (esDbf != null) {
            final loteEs = esSinLote ? '' : lote;
            esEmpr++;
            esDbf.appendRecord(_esRecord(
              codigoEs: esEmpr, codigoArt: codigoArt, tipo: 'S',
              descri: 'INVENTARIO ANTES', origen: almInt, destin: 0,
              unidad: loteSnap, precio: precioCoste, fecha: fechaInv,
              lote: loteEs, fechaMod: fechaMod, usuario: usuario,
            ));
            esEmpr++;
            esDbf.appendRecord(_esRecord(
              codigoEs: esEmpr, codigoArt: codigoArt, tipo: 'E',
              descri: 'INVENTARIO OK', origen: 0, destin: almInt,
              unidad: newLoteStock, precio: precioCoste, fecha: fechaInv,
              lote: loteEs, fechaMod: fechaMod, usuario: usuario,
            ));
            movimientos += 2;
          }
        }
        modificados++;
      }

      // Actualizar contador E_S_EMPR en PARAMETR
      if (parDbf != null && parEmprIdx >= 0 && movimientos > 0) {
        parDbf.setFields(parEmprIdx, {'VALOR_PAR': esEmpr.toString()});
      }

      // Regenerar en memoria los índices NTX de los DBF cuyo contenido
      // indexado cambió: appends (registros nuevos fuera del árbol B) o
      // cambios de FECCAD_LOT. Los updates de stock no tocan ninguna clave.
      final ntxFiles = <String, Uint8List>{};
      if (stoDbf.hasAppends || stocklotClaveCambiada) {
        await _regenerarIndices(smb, 'STOCKLOT.DBF', stoDbf, ntxFiles, fase);
      }
      if (esDbf != null && movimientos > 0) {
        await _regenerarIndices(smb, 'E_S_ALMA.DBF', esDbf, ntxFiles, fase);
      }

      fase('índices regenerados en memoria: ${ntxFiles.length} '
          '(${(ntxFiles.values.fold<int>(0, (s, b) => s + b.length) / 1024).round()} KB)');

      // Escribir al servidor (aún con nombre temporal) solo lo cambiado:
      // registros modificados + appends + header, no los archivos enteros.
      await _writeDbfRanges(smb, _lockedName(acquired, 'ARTICULO.DBF'), artDbf);
      await _writeDbfRanges(smb, _lockedName(acquired, 'STOCKLOT.DBF'), stoDbf);
      if (esDbf  != null && movimientos > 0) {
        await _writeDbfRanges(smb, _lockedName(acquired, 'E_S_ALMA.DBF'), esDbf);
      }
      fase('DBF actualizados por rangos: ARTICULO ${artDbf.dirtyRecords.length} '
          'modificados, STOCKLOT ${stoDbf.dirtyRecords.length} modificados '
          '+${stoDbf.numRecords - stoDbf.originalNumRecords} nuevos, '
          'E_S_ALMA +${esDbf == null ? 0 : esDbf.numRecords - esDbf.originalNumRecords} movimientos');

      // PARAMETR.DBF: escritura por rango de solo los bytes VALOR_PAR del
      // registro E_S_EMPR. Reescribir el archivo entero pisaría contadores
      // (facturas, albaranes...) que otros puestos actualizan en paralelo.
      if (parDbf != null && parEmprIdx >= 0 && movimientos > 0) {
        final slice = parDbf.fieldSlice(parEmprIdx, 'VALOR_PAR');
        final data = parDbf.fieldBytes(parEmprIdx, 'VALOR_PAR');
        if (slice != null && data != null) {
          await smb
              .writeFileRange(_path('PARAMETR.DBF'), Uint8List.fromList(data),
                  offset: slice.offset)
              .timeout(_smbTimeout);
        }
      }

      // Escribir índices regenerados (nombre definitivo: ningún puesto puede
      // tener la tabla abierta mientras su DBF está renombrado)
      for (final e in ntxFiles.entries) {
        await _writeFile(smb, e.key, e.value);
        // writeFile no trunca: si el índice anterior era mayor quedaría cola
        // muerta (p. ej. E_S_AL_5 de 380MB tras subir 75MB).
        await smb.truncate(_path(e.key), e.value.length).timeout(_smbTimeout);
        fase('subido índice ${e.key} (${(e.value.length / 1024).round()} KB)');
      }

      // Verificación: el contador de registros de E_S_ALMA en el servidor
      // debe reflejar los movimientos añadidos.
      if (esDbf != null && movimientos > 0) {
        final head = await smb
            .readFileRange(_path(_lockedName(acquired, 'E_S_ALMA.DBF')),
                offset: 4, length: 4)
            .timeout(_smbTimeout);
        final n = ByteData.sublistView(head).getUint32(0, Endian.little);
        fase('verificación E_S_ALMA: $n registros en servidor '
            '(esperados ${esDbf.numRecords})');
        if (n != esDbf.numRecords) {
          throw LegacyException(
              'Verificación fallida: E_S_ALMA quedó con $n registros, '
              'esperados ${esDbf.numRecords}');
        }
      }

      envioCompletado = true;
      LogService.auditar('ENVÍO inventario alm $almacen completado: '
          '$inventariados artículos, $movimientos movimientos E/S');
      return LegacyEnvioResult(
        modificados: modificados,
        inventariados: inventariados,
        movimientos: movimientos,
      );
    } finally {
      final pendientes = await _releaseExclusive(smb, acquired);
      await _safeDisconnect(smb);
      // Solo elevar el fallo de restauración si no hay ya una excepción en
      // vuelo (no enmascarar la causa original; el siguiente intento detecta
      // los .PDA huérfanos al adquirir el lock).
      if (envioCompletado && pendientes.isNotEmpty) {
        throw LegacyException(
            'Envío completado, pero no se pudo restaurar el nombre de: '
            '${pendientes.map((f) => '$f$_lockSuffix').join(', ')}. '
            'Renómbralos quitando "$_lockSuffix" antes de usar GC.');
      }
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
    var acquired = const <String>[];
    var completado = false;
    try {
      acquired = await _acquireExclusive(smb, ['ARTICULO.DBF']);
      final artDbf = DbfFile.open(await _readFile(smb, _lockedName(acquired, 'ARTICULO.DBF')));
      final idx = artDbf.findByKey({'CODIGO_ART': codigoArt});
      if (idx < 0) throw LegacyException('Artículo no encontrado: $codigoArt');
      final updates = <String, dynamic>{};
      if (cbarra    != null) updates['CBARRA_ART']  = cbarra;
      if (ubicacion != null) updates['UBICAC_ART']  = ubicacion;
      if (peso      != null) updates['PESO_ART']    = peso;
      if (unicaj    != null) updates['UNICAJ_ART']  = unicaj;
      if (unipal    != null) updates['UNIPAL_ART']  = unipal;
      if (updates.isNotEmpty) {
        artDbf.setFields(idx, updates);
        await _writeDbfRanges(smb, _lockedName(acquired, 'ARTICULO.DBF'), artDbf);
        // Solo CBARRA_ART forma parte de una clave de índice (ARTIC_4):
        // regenerar los índices de ARTICULO únicamente si cambió.
        if (cbarra != null) {
          final ntxFiles = <String, Uint8List>{};
          await _regenerarIndices(smb, 'ARTICULO.DBF', artDbf, ntxFiles,
              (m) => LogService.registrar('GUARDAR ART: $m'));
          for (final e in ntxFiles.entries) {
            await _writeFile(smb, e.key, e.value);
            await smb.truncate(_path(e.key), e.value.length).timeout(_smbTimeout);
          }
        }
      }
      completado = true;
    } finally {
      final pendientes = await _releaseExclusive(smb, acquired);
      await _safeDisconnect(smb);
      if (completado && pendientes.isNotEmpty) {
        throw LegacyException(
            'Guardado, pero no se pudo restaurar el nombre de: '
            '${pendientes.map((f) => '$f$_lockSuffix').join(', ')}. '
            'Renómbralos quitando "$_lockSuffix" antes de usar GC.');
      }
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
  final Set<String> tipos;                // vacío = sin filtro de tipo
  final Map<int, String> clases;          // clave 1-5 → código clase; vacío = sin filtro
  const LegacyFiltros({
    this.proveedor,
    this.familia,
    this.tipos = const {},
    this.clases = const {},
  });
}

extension _StringX on String {
  String? nullIfEmpty() => isEmpty ? null : this;
}
