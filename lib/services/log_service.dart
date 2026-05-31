import 'dart:io';
import 'package:path_provider/path_provider.dart';

enum LogNivel { info, error }

class LogEntry {
  final DateTime timestamp;
  final String mensaje;
  final LogNivel nivel;

  LogEntry(this.timestamp, this.mensaje, this.nivel);

  bool get isError => nivel == LogNivel.error;

  String toLine() {
    final n = isError ? 'E' : 'I';
    return '${timestamp.toIso8601String()}|$n|$mensaje';
  }

  static LogEntry? fromLine(String line) {
    final parts = line.split('|');
    if (parts.length < 3) return null;
    final ts = DateTime.tryParse(parts[0]);
    if (ts == null) return null;
    final nivel = parts[1] == 'E' ? LogNivel.error : LogNivel.info;
    final msg = parts.sublist(2).join('|');
    return LogEntry(ts, msg, nivel);
  }
}

class LogService {
  static const _maxEntradas = 300;
  static const _fileName = 'inventario_log.txt';

  static Future<File> _archivo() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Registra un mensaje. Llamar con `isError: true` para errores.
  static void registrar(String mensaje, {bool isError = false}) {
    _escribir(mensaje, isError ? LogNivel.error : LogNivel.info);
  }

  static void _escribir(String mensaje, LogNivel nivel) async {
    try {
      final file = await _archivo();
      final entry = LogEntry(DateTime.now(), mensaje, nivel);
      await file.writeAsString('${entry.toLine()}\n',
          mode: FileMode.append, flush: true);
      await _rotarSiNecesario(file);
    } catch (_) {}
  }

  static Future<void> _rotarSiNecesario(File file) async {
    try {
      final lineas = await file.readAsLines();
      if (lineas.length > _maxEntradas) {
        final recorte = lineas.skip(lineas.length - _maxEntradas).join('\n');
        await file.writeAsString('$recorte\n');
      }
    } catch (_) {}
  }

  /// Devuelve las entradas ordenadas de más reciente a más antigua.
  static Future<List<LogEntry>> obtenerRegistros() async {
    try {
      final file = await _archivo();
      if (!await file.exists()) return [];
      final lineas = await file.readAsLines();
      return lineas.reversed
          .map(LogEntry.fromLine)
          .whereType<LogEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> limpiar() async {
    try {
      final file = await _archivo();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Traduce excepciones técnicas a texto comprensible para el usuario.
  static String traducirError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('Network is unreachable')) {
      return 'No se pudo conectar al servidor (sin red o servidor apagado)';
    }
    if (s.contains('TimeoutException') || s.contains('timeout')) {
      return 'La conexión tardó demasiado y se canceló (tiempo de espera agotado)';
    }
    if (s.contains('HandshakeException') || s.contains('certificate')) {
      return 'Error de seguridad en la conexión (certificado SSL inválido)';
    }
    if (s.contains('401') || s.contains('Unauthorized')) {
      return 'Credenciales incorrectas (usuario o contraseña inválidos)';
    }
    if (s.contains('403') || s.contains('Forbidden')) {
      return 'Sin permiso para acceder a este recurso';
    }
    if (s.contains('404') || s.contains('Not Found')) {
      return 'Recurso no encontrado en el servidor';
    }
    if (s.contains('500') || s.contains('Internal Server Error')) {
      return 'Error interno del servidor';
    }
    if (s.contains('SMB') || s.contains('smb') || s.contains('Smb')) {
      return 'Error al conectar con el servidor de archivos (SMB)';
    }
    if (s.contains('DatabaseException') || s.contains('SqliteException')) {
      return 'Error en la base de datos local';
    }
    if (s.contains('FormatException') || s.contains('JSON')) {
      return 'Los datos recibidos del servidor tienen un formato incorrecto';
    }
    if (s.contains('PathNotFoundException') || s.contains('No such file')) {
      return 'No se encontró el archivo en el servidor';
    }
    // Recortar mensajes muy largos
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}
