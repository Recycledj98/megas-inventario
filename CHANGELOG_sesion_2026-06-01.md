# Sesión de trabajo — 2026-06-01

## Cambios realizados

### 2.1.6+33 — Mejora UX pantalla de lotes
- `LotEditorScreen`: eliminado el FAB inferior de "Añadir cantidad"
- Añadido panel lateral derecho (110 px, igual al de la pantalla principal) con:
  - Botón **Añadir cantidad** siempre visible, ocupa la mayor parte del panel
  - Stock total del artículo visible en la parte inferior del panel

### 2.1.7+34 — Lotes en tabla con columnas
- `LotEditorScreen`: rediseño completo del listado de lotes al estilo de la pantalla principal
  - Selector de pestaña (chips) con el mismo estilo que `_ConteoFilterRow`:
    - **En sesión (N)** — líneas contadas en la sesión actual
    - **Lotes en stock (N)** — lotes disponibles en el servidor
  - Cabecera de tabla con columnas: Código lote | Caducidad | Cantidad/Stock | Acciones
  - Filas compactas de 44 px alineadas por columna
  - Lotes ya contados resaltados en azul tenue con icono de tick

### 2.1.8+35 — Registro de incidencias
- Nuevo `LogService` (`lib/services/log_service.dart`):
  - Escribe a `inventario_log.txt` en almacenamiento interno (máx. 300 entradas)
  - `registrar(msg, isError: bool)` — llamado desde cada bloque `catch`
  - `traducirError(e)` — traduce excepciones técnicas al español
- Nueva `LogScreen` (`lib/screens/log_screen.dart`):
  - Chips: Todos / Solo errores
  - Botón copiar todo al portapapeles
  - Botón limpiar
- Acceso: Configuración → **Registro de incidencias** (debajo de "Acerca de")
- Integración en: sync API, recepción legacy, envío inventario, prueba conexión SMB, guardar artículo

### 2.1.9+36 — Errores SMB más precisos
- `LogService.traducirError`: checks de NTSTATUS específicos **antes** del catch genérico de SMB:
  - `STATUS_OBJECT_NAME_NOT_FOUND` → "Archivo no encontrado (¿cambió el nombre del DBF?)"
  - `STATUS_ACCESS_DENIED` → "Sin permiso / fichero en uso"
  - `STATUS_LOGON_FAILURE` → "Usuario o contraseña incorrectos"
  - `STATUS_BAD_NETWORK_PATH` → "Carpeta compartida no existe"
  - SMB genérico solo si no encaja ninguno de los anteriores
- Todos los mensajes incluyen el error técnico raw para el técnico

### 2.2.0+37 — Auditoría permanente
- Nuevo archivo `inventario_auditoria.txt`: **nunca se borra**, sin límite de entradas
- `LogService.auditar(msg)` — método separado que escribe solo en el archivo de auditoría
- Eventos auditados:
  - Nueva sesión de inventario creada (usuario, almacén, descripción)
  - Recepción completada (artículos y lotes)
  - Inventario enviado (líneas, sesión, usuario)
  - Configuración guardada (modo, servidor/empresa, usuario)
- `LogScreen` actualizada con dos vistas:
  - **Incidencias** — errores, borrable, subfiltro Todos/Solo errores
  - **Auditoría** — movimientos permanentes, icono 🔒 "Solo lectura", sin botón limpiar

### Pendiente (sin APK todavía)
- Botones Config y Salir en horizontal ligeramente más grandes:
  - Icono 13 → 18 px, texto 9 → 12 px, `FontWeight.w500`, padding 6 → 10 px, opacidad eliminada (color sólido)
