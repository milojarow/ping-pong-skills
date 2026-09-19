# Receptor Grok

Usa el `PP` de la skill que cargaste y confirma `harness=grok` con `--whoami`.

## Abrir o unirse y armar

1. `"$PP" --open --topic "<tema>"` o `"$PP" --join <id>`.
2. `"$PP" --keep <id>`.
3. Herramienta `monitor` con `command: "<ruta PP> --watch <id>"` y `persistent: true`.
4. Entrega el id, o saluda una vez si eres joiner. Espera al operador.

## Qué recibe el modelo, drenar y rearmar

Cada línea de stdout del monitor llega dentro de `<monitor-event ...>`, con su texto. `MAIL <id>` es el timbre: ejecuta `"$PP" --await <id>` en primer plano y aplica el contrato de alcance al cuerpo.

El monitor sigue armado tras drenar; no abras otro lector FIFO ni otro monitor por turno. `WATCH armed` es diagnóstico en stderr, no un mensaje del peer. `KEEPER` o `GONE` con exit 2 indican fin de recepción: no relances contra un canal cerrado. Si el proceso monitor termina mientras keeper y canal siguen vivos, rearma una vez; un fallo repetido exige declarar degradación, no un loop de turnos.

El watcher anuncia crecimiento por estado. Varios eventos pueden corresponder a un mismo drenaje: después de drenar un lote, usa `--await <id> --wait 1` para un aviso atrasado y trata exit 124 como ausencia de correo.

## Cierre y propiedad

`"$PP" --close <id>` al acabar; la correa funciona también para `grok:<pid>`. Deja terminar/cancela el monitor al cerrar. No adoptes sin encargo. Correo pendiente se conserva para recuperación, sin despertar una sesión cerrada.

## Modo degradado

Sin monitor persistente: espera acotada con `--await <id> --wait N` en primer plano. Si el operador eligió usar `run_terminal_command` de fondo, su aviso de finalización **no trae stdout**: llama `get_command_or_subagent_output("<id de tarea>")` antes de interpretar el resultado. No confundas el aviso con el cuerpo ni drenes una segunda vez un await que ya terminó.

Sin keeper o en modo directo solicitado: `--listen <id> --wait N`, en primer plano, sin promesa de despertar entre turnos.
