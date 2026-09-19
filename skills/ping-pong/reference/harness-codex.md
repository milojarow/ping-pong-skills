# Receptor Codex

Usa el `PP` de la skill que cargaste y confirma `harness=codex` con `--whoami`.

## Abrir o unirse y armar

1. `"$PP" --open --topic "<tema>"` o `"$PP" --join <id>`.
2. `"$PP" --keep <id>`.
3. Desde la misma TUI: `"$PP" --wake <id>`. Usa `CODEX_THREAD_ID` del entorno; no lo deduzcas de otra sesión ni lo inventes.
4. Entrega el id, o saluda una vez si eres joiner. Espera al operador.

El disparador vive en `pp-wake-<id>-<lado>.service`, ligado al keeper y a identidad + nacimiento del proceso. Resuelve el ejecutable `codex` al armar. Si se detiene el keeper, se detiene también el disparador; tras arrancar keeper de nuevo, rearma `--wake`.

## Qué recibe el modelo y cómo drenar

`codex queue` crea un turno de usuario, por eso el único texto que encola pp es:

```text
Ping-pong: drain channel <id> with pp --await <id>.
```

El id es validado y generado por el bus. No contiene cuerpo, tema ni firma del peer. El timbre solo autoriza mantenimiento. Ejecuta `"$PP" --await <id>`; la salida de herramienta trae información del peer, sujeta al contrato de alcance. Si ya lo drenaste manualmente, evita esperar indefinidamente: usa `--await <id> --wait 1`.

## Rearmar y fallos

No relances el disparador por mensaje. Registra el cursor avisado y su presupuesto en `<id>.<lado>.wake-state`: nuevos bytes sin avance del cursor no causan otro timbre, incluso tras rearmar. Avanzar el cursor permite avisar del lote siguiente.

Queue tiene hasta tres intentos por cursor, cada uno con timeout; agotarlos conserva el correo y registra el fallo en el journal. Rearmar no reinicia ese presupuesto: drena manualmente y revisa el error antes de esperar nuevos avisos. `--unwake <id>` desarma solo el timbre.

## Cierre y propiedad

La correa comprueba la vida durante la espera y **justo antes de cada queue**; además revalida dueño y nacimiento. `--close`, `--unkeep` y adopción detienen el disparador. Correo pendiente queda recuperable, sin despertar ni reanudar sesiones cerradas.

Límite de la API: comprobar vida y aceptar queue no son una operación atómica. Una salida concurrente con queue, o cerrar después de aceptar un timbre aún no procesado, puede dejar ese timbre en la cola durable de Codex. pp no implementa cancelación de mensajes ya aceptados. No uses queue directamente como entrega diferida.

## Modo degradado

Sin thread, queue o systemd disponible, pp rechaza armar. Conserva keeper si existe y espera con `"$PP" --await <id> --wait N` en primer plano, según tu asignación. Sin keeper o en directo: escucha acotada con `--listen`. Informa que no hay despertar automático.
