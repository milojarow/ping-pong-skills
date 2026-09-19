# Receptor Claude Code

Usa el `PP` de la skill que cargaste y confirma `harness=claude` con `--whoami`.

## Abrir o unirse

1. Iniciador: `"$PP" --open --topic "<tema>"`; joiner: `"$PP" --join <id>`.
2. `"$PP" --keep <id>`: espera la confirmación de lector conectado.
3. Arma `Bash(command: "<ruta PP> --await <id>", run_in_background: true)`.
4. Entrega el id, o saluda una sola vez si eres joiner. Espera al operador.

## Despertar, drenar y rearmar

El fin del Bash de fondo despierta la sesión. El aviso puede traer la salida o su ruta: recupera la salida completa con la herramienta de tareas/lectura del arnés. **Exit 0 ya drenó el cuerpo**; no ejecutes otro await para recuperar ese mismo mensaje.

Relanza un único await de fondo para el siguiente lote antes de trabajar o responder. El mantenimiento sigue autorizado aunque el mensaje del peer no traiga trabajo asignado. Aplica el contrato de alcance al cuerpo.

Si el arnés mata la tarea sin entregar correo, rearma silenciosamente mientras el keeper y la sesión sigan vivos. Si vuelve a matarla inmediatamente, declara modo degradado; no generes una cadena de turnos vacíos. Exit 3 sin correo significa keeper parado o canal cerrado: no rearmes hasta confirmar un keeper válido. No abras otro canal sin encargo.

Claude Monitor no tiene `persistent` en el arnés medido y expira a los 30 minutos. No lo uses como receta por defecto ni confundas la herramienta `monitor` de Grok con ésta.

## Cierre y propiedad

`"$PP" --close <id>` al acabar la colaboración. El hook SessionEnd y la correa cubren salida normal y muerte del proceso. No adoptes otro dueño sin encargo. Pendientes al cerrar se recuperan con el comando impreso por pp; no se despierta una sesión cerrada.

## Modo degradado

Sin Bash de fondo utilizable: `"$PP" --await <id> --wait N` en primer plano cuando debas esperar. Sin keeper: `--listen <id> --wait N`. El modo directo pedido por el operador usa esa escucha acotada. Informa que no hay despertar entre turnos.
