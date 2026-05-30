import 'package:drift/drift.dart';

// Cache de artículos descargados del servidor
class ArticulosLocal extends Table {
  IntColumn get articuloId => integer()();
  IntColumn get empresaId => integer()();
  TextColumn get identificacion => text().withDefault(const Constant(''))();
  TextColumn get descripcion1 => text().nullable()();
  TextColumn get descripcion2 => text().nullable()();
  TextColumn get codigoAlternativo1 => text().nullable()(); // barcode principal
  TextColumn get codigoAlternativo2 => text().nullable()(); // barcode secundario
  IntColumn get familiaId => integer()();
  TextColumn get familiaNombre => text().withDefault(const Constant(''))();
  IntColumn get proveedorId => integer()();
  TextColumn get proveedorNombre => text().withDefault(const Constant(''))();
  RealColumn get stockMinimo => real().withDefault(const Constant(0))();
  RealColumn get stockMaximo => real().withDefault(const Constant(0))();
  TextColumn get imagenUrl => text().nullable()();
  TextColumn get ubicacion => text().nullable()();
  RealColumn get peso    => real().nullable()();
  RealColumn get unicaj  => real().nullable()();
  RealColumn get unipal  => real().nullable()();
  TextColumn get activo => text().withDefault(const Constant('Y'))();
  DateTimeColumn get ultimaSync => dateTime()();

  @override
  Set<Column> get primaryKey => {articuloId, empresaId};
}

// Cache de almacenes descargados del servidor
class AlmacenesLocal extends Table {
  IntColumn get almacenId => integer()();
  IntColumn get empresaId => integer()();
  TextColumn get nombre => text()();
  TextColumn get direccion => text().withDefault(const Constant(''))();
  TextColumn get poblacion => text().withDefault(const Constant(''))();
  TextColumn get activo => text().withDefault(const Constant('Y'))();

  @override
  Set<Column> get primaryKey => {almacenId, empresaId};
}

// Cabeceras de inventario creadas en la app
class CabecerasInventarioLocal extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get servidorId => integer().nullable()(); // null = no sincronizado
  IntColumn get empresaId => integer()();
  IntColumn get almacenId => integer()();
  DateTimeColumn get fechaOperacion => dateTime()();
  TextColumn get descripcion => text()();
  BoolColumn get sincronizado => boolean().withDefault(const Constant(false))();
  DateTimeColumn get fechaSync => dateTime().nullable()();
  DateTimeColumn get fechaCreacion => dateTime()();
}

// Líneas de inventario (artículos contados)
class LineasInventarioLocal extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get servidorId => integer().nullable()(); // null = no sincronizado
  IntColumn get cabeceraId => integer().references(CabecerasInventarioLocal, #id)();
  IntColumn get articuloId => integer()();
  // Desnormalizado para disponibilidad offline
  TextColumn get articuloDescripcion => text().withDefault(const Constant(''))();
  TextColumn get articuloCodigo => text().withDefault(const Constant(''))();
  IntColumn get almacenId => integer()();
  RealColumn get stock => real().withDefault(const Constant(0))();
  TextColumn get codigoLote => text().nullable()();
  DateTimeColumn get fechaCaducidad => dateTime().nullable()();
  DateTimeColumn get fechaAlta => dateTime()();
  BoolColumn get sincronizado => boolean().withDefault(const Constant(false))();
}

// Stock consultado y cacheado del servidor
class StockLocal extends Table {
  IntColumn get empresaId => integer()();
  IntColumn get almacenId => integer()();
  IntColumn get articuloId => integer()();
  RealColumn get unidades => real().withDefault(const Constant(0))();
  RealColumn get precioCoste => real().withDefault(const Constant(0))();
  DateTimeColumn get fechaStock => dateTime()();
  DateTimeColumn get ultimaSync => dateTime()();

  @override
  Set<Column> get primaryKey => {empresaId, almacenId, articuloId};
}

// Lotes de stock cacheados
class StockLotesLocal extends Table {
  IntColumn get stockLoteId => integer()();
  IntColumn get empresaId => integer()();
  IntColumn get articuloId => integer()();
  IntColumn get almacenId => integer()();
  TextColumn get codigoLote => text()();
  DateTimeColumn get fechaCaducidad => dateTime()();
  RealColumn get stock => real().withDefault(const Constant(0))();
  DateTimeColumn get ultimaSync => dateTime()();

  @override
  Set<Column> get primaryKey => {stockLoteId};
}
