import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [
  ArticulosLocal,
  AlmacenesLocal,
  CabecerasInventarioLocal,
  LineasInventarioLocal,
  StockLocal,
  StockLotesLocal,
])
class AppDatabase extends _$AppDatabase {
  static AppDatabase? _instance;

  factory AppDatabase() {
    _instance ??= AppDatabase._internal();
    return _instance!;
  }

  AppDatabase._internal() : super(_openConnection());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(articulosLocal, articulosLocal.ubicacion);
          }
          if (from < 3) {
            await m.addColumn(articulosLocal, articulosLocal.peso);
            await m.addColumn(articulosLocal, articulosLocal.unicaj);
            await m.addColumn(articulosLocal, articulosLocal.unipal);
          }
          if (from < 4) {
            await m.addColumn(articulosLocal, articulosLocal.clase1);
            await m.addColumn(articulosLocal, articulosLocal.clase2);
            await m.addColumn(articulosLocal, articulosLocal.clase3);
            await m.addColumn(articulosLocal, articulosLocal.clase4);
            await m.addColumn(articulosLocal, articulosLocal.clase5);
          }
        },
      );

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'megas_inventario');
  }

  // --- Artículos ---

  Future<List<ArticulosLocalData>> getArticulos(
    int empresaId, {
    String? search,
    String? proveedorNombre,
    String? familiaNombre,
    String? clase1,
    String? clase2,
    String? clase3,
    String? clase4,
    String? clase5,
    String sortOrder = 'ubicacion',
  }) {
    final q = select(articulosLocal)
      ..where((t) => t.empresaId.equals(empresaId) & t.activo.equals('Y'));
    if (search != null && search.isNotEmpty) {
      q.where((t) =>
          t.descripcion1.like('%$search%') |
          t.descripcion2.like('%$search%') |
          t.codigoAlternativo1.like('%$search%') |
          t.codigoAlternativo2.like('%$search%') |
          t.identificacion.like('%$search%'));
    }
    if (proveedorNombre != null) q.where((t) => t.proveedorNombre.equals(proveedorNombre));
    if (familiaNombre   != null) q.where((t) => t.familiaNombre.equals(familiaNombre));
    if (clase1 != null) q.where((t) => t.clase1.equals(clase1));
    if (clase2 != null) q.where((t) => t.clase2.equals(clase2));
    if (clase3 != null) q.where((t) => t.clase3.equals(clase3));
    if (clase4 != null) q.where((t) => t.clase4.equals(clase4));
    if (clase5 != null) q.where((t) => t.clase5.equals(clase5));
    switch (sortOrder) {
      case 'codigo':
        q.orderBy([(t) => OrderingTerm.asc(t.identificacion)]);
      case 'alfabetico':
        q.orderBy([(t) => OrderingTerm.asc(t.descripcion1)]);
      case 'proveedor':
        q.orderBy([(t) => OrderingTerm.asc(t.proveedorNombre),
                   (t) => OrderingTerm.asc(t.descripcion1)]);
      case 'familia':
        q.orderBy([(t) => OrderingTerm.asc(t.familiaNombre),
                   (t) => OrderingTerm.asc(t.descripcion1)]);
      default: // 'ubicacion'
        q.orderBy([(t) => OrderingTerm.asc(t.ubicacion),
                   (t) => OrderingTerm.asc(t.identificacion)]);
    }
    return q.get();
  }

  /// Devuelve valores distintos de clase[n] (1-5) respetando los filtros de
  /// clases superiores ya seleccionados (cascade).
  Future<List<String>> getDistinctClase(
    int empresaId,
    int n, {
    String? clase1, String? clase2, String? clase3, String? clase4,
    String? proveedorNombre, String? familiaNombre,
  }) async {
    final col = switch (n) {
      1 => 'clase1', 2 => 'clase2', 3 => 'clase3',
      4 => 'clase4', _ => 'clase5',
    };
    final where = StringBuffer("empresa_id = ? AND activo = 'Y' AND $col IS NOT NULL AND $col != ''");
    final vars  = <Variable>[Variable.withInt(empresaId)];
    if (n > 1 && clase1 != null) { where.write(' AND clase1 = ?'); vars.add(Variable.withString(clase1)); }
    if (n > 2 && clase2 != null) { where.write(' AND clase2 = ?'); vars.add(Variable.withString(clase2)); }
    if (n > 3 && clase3 != null) { where.write(' AND clase3 = ?'); vars.add(Variable.withString(clase3)); }
    if (n > 4 && clase4 != null) { where.write(' AND clase4 = ?'); vars.add(Variable.withString(clase4)); }
    if (proveedorNombre != null) { where.write(' AND proveedor_nombre = ?'); vars.add(Variable.withString(proveedorNombre)); }
    if (familiaNombre   != null) { where.write(' AND familia_nombre = ?');   vars.add(Variable.withString(familiaNombre)); }
    final rows = await customSelect(
      'SELECT DISTINCT $col FROM articulos_local WHERE $where ORDER BY $col',
      variables: vars,
      readsFrom: {articulosLocal},
    ).get();
    return rows.map((r) => r.read<String>(col)).toList();
  }

  Future<ArticulosLocalData?> getArticuloById(int empresaId, int articuloId) {
    return (select(articulosLocal)
          ..where((t) =>
              t.empresaId.equals(empresaId) &
              t.articuloId.equals(articuloId)))
        .getSingleOrNull();
  }

  Future<ArticulosLocalData?> getArticuloByBarcode(int empresaId, String barcode) {
    return (select(articulosLocal)
          ..where((t) =>
              t.empresaId.equals(empresaId) &
              (t.codigoAlternativo1.equals(barcode) |
               t.codigoAlternativo2.equals(barcode) |
               t.identificacion.equals(barcode))))
        .getSingleOrNull();
  }

  Future<void> upsertArticulos(List<ArticulosLocalCompanion> rows) async {
    await batch((b) => b.insertAllOnConflictUpdate(articulosLocal, rows));
  }

  Future<List<String>> getDistinctProveedores(int empresaId) async {
    final rows = await customSelect(
      'SELECT DISTINCT proveedor_nombre FROM articulos_local '
      "WHERE empresa_id = ? AND activo = 'Y' AND proveedor_nombre != '' "
      'ORDER BY proveedor_nombre',
      variables: [Variable.withInt(empresaId)],
      readsFrom: {articulosLocal},
    ).get();
    return rows.map((r) => r.read<String>('proveedor_nombre')).toList();
  }

  Future<List<String>> getDistinctFamilias(int empresaId) async {
    final rows = await customSelect(
      'SELECT DISTINCT familia_nombre FROM articulos_local '
      "WHERE empresa_id = ? AND activo = 'Y' AND familia_nombre != '' "
      'ORDER BY familia_nombre',
      variables: [Variable.withInt(empresaId)],
      readsFrom: {articulosLocal},
    ).get();
    return rows.map((r) => r.read<String>('familia_nombre')).toList();
  }

  Future<void> updateArticuloFields(int empresaId, int articuloId, {
    String? cbarra, String? ubicacion, double? peso, double? unicaj, double? unipal,
  }) {
    return (update(articulosLocal)..where((t) =>
            t.empresaId.equals(empresaId) & t.articuloId.equals(articuloId)))
        .write(ArticulosLocalCompanion(
          codigoAlternativo1: cbarra    != null ? Value(cbarra)    : const Value.absent(),
          ubicacion:          ubicacion != null ? Value(ubicacion) : const Value.absent(),
          peso:               peso      != null ? Value(peso)      : const Value.absent(),
          unicaj:             unicaj    != null ? Value(unicaj)    : const Value.absent(),
          unipal:             unipal    != null ? Value(unipal)    : const Value.absent(),
        ));
  }

  // --- Almacenes ---

  Future<List<AlmacenesLocalData>> getAlmacenes(int empresaId) {
    return (select(almacenesLocal)
          ..where((t) => t.empresaId.equals(empresaId) & t.activo.equals('Y')))
        .get();
  }

  Future<void> upsertAlmacenes(List<AlmacenesLocalCompanion> rows) async {
    await batch((b) => b.insertAllOnConflictUpdate(almacenesLocal, rows));
  }

  // --- Inventarios: cabeceras ---

  Future<List<CabecerasInventarioLocalData>> getCabeceras(int empresaId) {
    return (select(cabecerasInventarioLocal)
          ..where((t) => t.empresaId.equals(empresaId))
          ..orderBy([(t) => OrderingTerm.desc(t.fechaCreacion)]))
        .get();
  }

  Future<CabecerasInventarioLocalData?> getCabecera(int id) {
    return (select(cabecerasInventarioLocal)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<int> insertCabecera(CabecerasInventarioLocalCompanion row) {
    return into(cabecerasInventarioLocal).insert(row);
  }

  Future<void> marcarCabeceraSync(int id, int servidorId) {
    return (update(cabecerasInventarioLocal)..where((t) => t.id.equals(id)))
        .write(CabecerasInventarioLocalCompanion(
          servidorId: Value(servidorId),
          sincronizado: const Value(true),
          fechaSync: Value(DateTime.now()),
        ));
  }

  Future<void> cerrarCabecera(int id) {
    return (update(cabecerasInventarioLocal)..where((t) => t.id.equals(id)))
        .write(CabecerasInventarioLocalCompanion(
          sincronizado: const Value(true),
          fechaSync: Value(DateTime.now()),
        ));
  }

  /// Elimina una cabecera de inventario y todas sus líneas.
  Future<void> deleteInventario(int cabeceraId) async {
    await (delete(lineasInventarioLocal)
          ..where((t) => t.cabeceraId.equals(cabeceraId)))
        .go();
    await (delete(cabecerasInventarioLocal)..where((t) => t.id.equals(cabeceraId)))
        .go();
  }

  // --- Inventarios: líneas ---

  Future<List<LineasInventarioLocalData>> getLineas(int cabeceraId) {
    return (select(lineasInventarioLocal)
          ..where((t) => t.cabeceraId.equals(cabeceraId))
          ..orderBy([(t) => OrderingTerm.desc(t.fechaAlta)]))
        .get();
  }

  Future<List<LineasInventarioLocalData>> getLineasPorArticulo(
      int cabeceraId, int articuloId) {
    return (select(lineasInventarioLocal)
          ..where((t) =>
              t.cabeceraId.equals(cabeceraId) &
              t.articuloId.equals(articuloId))
          ..orderBy([(t) => OrderingTerm.asc(t.fechaAlta)]))
        .get();
  }

  Future<int> insertLinea(LineasInventarioLocalCompanion row) {
    return into(lineasInventarioLocal).insert(row);
  }

  Future<void> updateLinea(int id, double stock, String? lote, DateTime? caducidad) {
    return (update(lineasInventarioLocal)..where((t) => t.id.equals(id))).write(
      LineasInventarioLocalCompanion(
        stock: Value(stock),
        codigoLote: Value(lote),
        fechaCaducidad: Value(caducidad),
      ),
    );
  }

  Future<void> deleteLinea(int id) {
    return (delete(lineasInventarioLocal)..where((t) => t.id.equals(id))).go();
  }

  Future<List<CabecerasInventarioLocalData>> getPendientesSync(int empresaId) {
    return (select(cabecerasInventarioLocal)
          ..where((t) =>
              t.empresaId.equals(empresaId) & t.sincronizado.equals(false)))
        .get();
  }

  // --- Stock ---

  Future<List<StockLocalData>> getStock(int empresaId, int articuloId) {
    return (select(stockLocal)
          ..where((t) =>
              t.empresaId.equals(empresaId) & t.articuloId.equals(articuloId)))
        .get();
  }

  Future<Map<int, double>> getStockTotalPorArticulo(int empresaId) async {
    // Base: snapshot de STOCK#_ART (stockLocal) para artículos sin trazabilidad
    final snapRows = await (select(stockLocal)
          ..where((t) => t.empresaId.equals(empresaId)))
        .get();
    final Map<int, double> result = {};
    for (final r in snapRows) {
      result[r.articuloId] = r.unidades;
    }
    // Override con suma de lotes reales (artículos con trazabilidad)
    final loteRows = await (select(stockLotesLocal)
          ..where((t) => t.empresaId.equals(empresaId)))
        .get();
    final Map<int, double> loteSums = {};
    for (final r in loteRows) {
      loteSums[r.articuloId] = (loteSums[r.articuloId] ?? 0.0) + r.stock;
    }
    result.addAll(loteSums);
    return result;
  }

  Future<void> upsertStock(List<StockLocalCompanion> rows) async {
    await batch((b) => b.insertAllOnConflictUpdate(stockLocal, rows));
  }

  Future<List<StockLotesLocalData>> getStockLotes(int empresaId, int articuloId) {
    return (select(stockLotesLocal)
          ..where((t) =>
              t.empresaId.equals(empresaId) & t.articuloId.equals(articuloId))
          ..orderBy([(t) => OrderingTerm.asc(t.fechaCaducidad)]))
        .get();
  }

  Future<void> upsertStockLotes(List<StockLotesLocalCompanion> rows) async {
    await batch((b) => b.insertAllOnConflictUpdate(stockLotesLocal, rows));
  }
}
