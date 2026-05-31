import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Síntesis física Karplus-Strong: modela la vibración de una cuerda o placa
/// metálica con reflexiones en los extremos. Produce sonidos de campana/marimba
/// físicamente realistas, a diferencia de las ondas sinusoidales puras.
class FeedbackService {
  static AudioPlayer? _player;

  // ── Biblioteca de sonidos (calculados una sola vez al arrancar) ─────────────

  // Tap: golpe seco muy corto, C7 (2093 Hz)
  static final _wavTap = _ks(2093.0, 0.055, decay: 0.9975, seed: 11);

  // Scan: campana brillante, E6 (1318 Hz) — como el "tink" de iOS
  static final _wavScan = _ks(1318.5, 0.38, decay: 0.9994, seed: 22);

  // Éxito: arpegio Do-Mi-Sol (C6-E6-G6), igual que el tri-tono de iOS payments
  static final _wavSuccess = _ksSeq(
    const [(1046.5, 0.000), (1318.5, 0.110), (1568.0, 0.220)],
    totalDur: 0.52,
    decay: 0.9995,
    seed: 33,
  );

  // Error: Sol4-Mi4 descendente, más oscuro y corto
  static final _wavError = _ksSeq(
    const [(392.0, 0.000), (329.63, 0.190)],
    totalDur: 0.55,
    decay: 0.9988,
    seed: 44,
  );

  // ── API pública ─────────────────────────────────────────────────────────────

  static Future<void> tap()     async { HapticFeedback.selectionClick(); _play(_wavTap);     }
  static Future<void> scan()    async { HapticFeedback.lightImpact();    _play(_wavScan);    }
  static Future<void> success() async { HapticFeedback.mediumImpact();   _play(_wavSuccess); }
  static Future<void> error()   async { HapticFeedback.heavyImpact();    _play(_wavError);   }

  static Future<void> _play(Uint8List wav) async {
    try {
      _player ??= AudioPlayer();
      await _player!.play(BytesSource(wav));
    } catch (_) {}
  }

  // ── Karplus-Strong: una sola nota ───────────────────────────────────────────
  //
  // Algoritmo: rellena un buffer de longitud N = sr/freq con ruido blanco
  // determinista (LCG). Cada muestra de salida es el promedio de dos muestras
  // adyacentes del buffer × factor de decaimiento. Esto simula las reflexiones
  // de una onda en los extremos de una cuerda o varilla metálica.
  //
  // decay cercano a 1.0 → campana larga; lejos de 1.0 → golpe seco corto.
  static Uint8List _ks(
    double freq,
    double dur, {
    required double decay,
    required int seed,
  }) {
    const sr     = 44100;
    final total  = (sr * dur).round();
    final period = (sr / freq).round().clamp(2, sr);

    final line = _noise(period, seed);
    final out  = Uint8List(44 + total * 2);
    final bd   = ByteData.view(out.buffer);
    _header(bd, out, sr, total);

    const fadeLen = 882; // 20 ms fade final para evitar click
    int pos = 0;
    for (var i = 0; i < total; i++) {
      final cur = line[pos];
      final nxt = (pos + 1) % period;
      // Filtro paso-bajo de 1er orden + atenuación → decaída natural
      line[pos] = (cur + line[nxt]) * 0.5 * decay;
      pos = nxt;

      final fade = i > total - fadeLen ? (total - i) / fadeLen : 1.0;
      bd.setInt16(44 + i * 2, (cur * 4500 * fade).round().clamp(-32768, 32767), Endian.little);
    }
    return out;
  }

  // ── Karplus-Strong: secuencia de notas mezcladas ────────────────────────────
  //
  // Genera varias notas K-S con desplazamientos temporales y las mezcla.
  // El resultado es un arpegio natural, como golpes rápidos sobre teclas.
  static Uint8List _ksSeq(
    List<(double freq, double offsetSec)> notes, {
    required double totalDur,
    required double decay,
    required int seed,
  }) {
    const sr    = 44100;
    final total = (sr * totalDur).round();
    final mix   = List<double>.filled(total, 0.0);

    for (var ni = 0; ni < notes.length; ni++) {
      final (freq, offset) = notes[ni];
      final start  = (offset * sr).round();
      final period = (sr / freq).round().clamp(2, sr);
      final line   = _noise(period, seed + ni * 7);

      int pos = 0;
      for (var i = 0; i < total - start; i++) {
        final cur = line[pos];
        final nxt = (pos + 1) % period;
        line[pos] = (cur + line[nxt]) * 0.5 * decay;
        pos = nxt;
        if (start + i < total) mix[start + i] += cur * 3500.0;
      }
    }

    // Normalizar para evitar clipping
    final peak = mix.fold(0.0, (m, v) => v.abs() > m ? v.abs() : m);
    final norm = peak > 4000.0 ? 4000.0 / peak : 1.0;

    final out = Uint8List(44 + total * 2);
    final bd  = ByteData.view(out.buffer);
    _header(bd, out, sr, total);

    const fadeLen = 882;
    for (var i = 0; i < total; i++) {
      final fade = i > total - fadeLen ? (total - i) / fadeLen : 1.0;
      bd.setInt16(44 + i * 2, (mix[i] * norm * fade).round().clamp(-32768, 32767), Endian.little);
    }
    return out;
  }

  // ── Ruido blanco determinista (LCG de Numerical Recipes) ───────────────────
  static List<double> _noise(int n, int seed) {
    var rng = seed;
    return List<double>.generate(n, (_) {
      rng = (rng * 1664525 + 1013904223) % 0x100000000;
      return (rng / 0x80000000) - 1.0; // rango [-1, 1]
    });
  }

  // ── Cabecera WAV PCM mono 44100 Hz ──────────────────────────────────────────
  static void _header(ByteData bd, Uint8List out, int sr, int n) {
    out.setAll(0,  [82, 73, 70, 70]);           // RIFF
    bd.setUint32(4, 36 + n * 2, Endian.little);
    out.setAll(8,  [87, 65, 86, 69]);           // WAVE
    out.setAll(12, [102, 109, 116, 32]);        // fmt
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1,  Endian.little);        // PCM
    bd.setUint16(22, 1,  Endian.little);        // mono
    bd.setUint32(24, sr, Endian.little);
    bd.setUint32(28, sr * 2, Endian.little);
    bd.setUint16(32, 2,  Endian.little);
    bd.setUint16(34, 16, Endian.little);
    out.setAll(36, [100, 97, 116, 97]);         // data
    bd.setUint32(40, n * 2, Endian.little);
  }
}
