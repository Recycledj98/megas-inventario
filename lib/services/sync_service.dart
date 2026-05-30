import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import '../database/database.dart';
import '../database/tables.dart';
import 'config_service.dart';

class SyncService {
  final AppDatabase _db;
  final Dio _dio;

  SyncService(this._db)
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 30),
        ));

  Future<bool> checkHealth() async {
    try {
      final resp = await _dio.get(ConfigService.apiUrl('/health'));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<SyncResult> syncArticulos() async {
    final empresaId = ConfigService.empresaId;
    int total = 0;
    int skip = 0;
    const limit = 500;

    try {
      while (true) {
        final resp = await _dio.get(
          ConfigService.apiUrl('/articulos'),
          queryParameters: {
            'empresa_id': empresaId,
            'limit': limit,
            'skip': skip,
            'activo': 'Y',
          },
        );
        final List<dynamic> data = resp.data as List<dynamic>;
        if (data.isEmpty) break;

        final rows = data.map((j) => ArticulosLocalCompanion(
              articuloId: Value(j['articulo_id'] as int),
              empresaId: Value(j['empresa_id'] as int),
              identificacion: Value(j['identificacion'] as String? ?? ''),
              descripcion1: Value(j['descripcion_articulo1'] as String?),
              descripcion2: Value(j['descripcion_articulo2'] as String?),
              codigoAlternativo1: Value(j['codigo_alternativo1'] as String?),
              codigoAlternativo2: Value(j['codigo_alternativo2'] as String?),
              familiaId: Value(j['familia_id'] as int),
              familiaNombre: Value(j['familia_nombre'] as String? ?? ''),
              proveedorId: Value(j['proveedor_id'] as int),
              proveedorNombre: Value(j['proveedor_nombre'] as String? ?? ''),
              stockMinimo: Value((j['stock_minimo'] as num?)?.toDouble() ?? 0),
              stockMaximo: Value((j['stock_maximo'] as num?)?.toDouble() ?? 0),
              imagenUrl: Value(j['imagen_url'] as String?),
              activo: Value(j['activo'] as String? ?? 'Y'),
              ultimaSync: Value(DateTime.now()),
            )).toList();

        await _db.upsertArticulos(rows);
        total += data.length;
        if (data.length < limit) break;
        skip += limit;
      }
      return SyncResult(articulos: total);
    } on DioException catch (e) {
      throw SyncException('Error conectando al servidor: ${e.message}');
    }
  }

  Future<SyncResult> syncAlmacenes() async {
    final empresaId = ConfigService.empresaId;
    try {
      final resp = await _dio.get(
        ConfigService.apiUrl('/almacenes'),
        queryParameters: {'empresa_id': empresaId},
      );
      final List<dynamic> data = resp.data as List<dynamic>;
      final rows = data.map((j) => AlmacenesLocalCompanion(
            almacenId: Value(j['almacen_id'] as int),
            empresaId: Value(j['empresa_id'] as int),
            nombre: Value(j['almacen'] as String? ?? ''),
            direccion: Value(j['direccion'] as String? ?? ''),
            poblacion: Value(j['poblacion'] as String? ?? ''),
            activo: Value(j['activo'] as String? ?? 'Y'),
          )).toList();
      await _db.upsertAlmacenes(rows);
      return SyncResult(almacenes: data.length);
    } on DioException catch (e) {
      throw SyncException('Error conectando al servidor: ${e.message}');
    }
  }

  Future<SyncResult> syncAll() async {
    final r1 = await syncArticulos();
    final r2 = await syncAlmacenes();
    return SyncResult(articulos: r1.articulos, almacenes: r2.almacenes);
  }

  /// Envía un inventario completo al servidor. Devuelve el cabecera_inventario_id asignado.
  Future<int> sendInventario(
    CabecerasInventarioLocalData cab,
    List<LineasInventarioLocalData> lineas,
  ) async {
    final data = {
      'empresa_id': cab.empresaId,
      'almacen_id': cab.almacenId,
      'fecha_operacion': cab.fechaOperacion.toIso8601String(),
      'descripcion': cab.descripcion,
      'usuario': ConfigService.usuario,
      'lineas': lineas.map((l) {
        final m = <String, dynamic>{
          'articulo_id': l.articuloId,
          'almacen_id': l.almacenId,
          'stock': l.stock,
        };
        if (l.codigoLote != null) m['codigo_lote'] = l.codigoLote;
        if (l.fechaCaducidad != null) {
          m['fecha_caducidad'] =
              l.fechaCaducidad!.toIso8601String().substring(0, 10);
        }
        return m;
      }).toList(),
    };
    try {
      final resp = await _dio.post(ConfigService.apiUrl('/inventarios'), data: data);
      return resp.data['cabecera_inventario_id'] as int;
    } on DioException catch (e) {
      throw SyncException('Error al enviar inventario: ${e.message}');
    }
  }

  /// Descarga stocks_lotes del servidor y los guarda localmente.
  Future<SyncResult> syncStock() async {
    final empresaId = ConfigService.empresaId;
    try {
      final resp = await _dio.get(
        ConfigService.apiUrl('/stock'),
        queryParameters: {'empresa_id': empresaId},
      );
      final List<dynamic> data = resp.data;
      final rows = data.map((j) => StockLotesLocalCompanion(
            stockLoteId: Value(j['stock_lote_id'] as int),
            empresaId: Value(j['empresa_id'] as int),
            articuloId: Value(j['articulo_id'] as int),
            almacenId: Value(j['almacen_id'] as int),
            codigoLote: Value(j['codigo_lote'] as String? ?? ''),
            fechaCaducidad: Value(
                DateTime.tryParse(j['fecha_caducidad'] as String? ?? '') ??
                    DateTime(2099)),
            stock: Value((j['stock'] as num).toDouble()),
            ultimaSync: Value(DateTime.now()),
          )).toList();
      await _db.upsertStockLotes(rows);
      return SyncResult(stockLotes: data.length);
    } on DioException catch (e) {
      throw SyncException('Error al recibir stock: ${e.message}');
    }
  }
}

class SyncResult {
  final int articulos;
  final int almacenes;
  final int stockLotes;
  const SyncResult({this.articulos = 0, this.almacenes = 0, this.stockLotes = 0});
}

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}
