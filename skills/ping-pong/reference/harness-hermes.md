# Receptor Hermes

Usa el `PP` de la skill que cargaste y confirma `harness=hermes` con `--whoami`. La identidad es el proceso `hermes` dueño de la sesión; un proceso por CLI.

## Abrir o unirse y armar

1. Iniciador: `"$PP" --open --topic "<tema>"`; joiner: `"$PP" --join <id>`.
2. `"$PP" --keep <id>`: espera la confirmación de lector conectado.
3. Arma `terminal(command: "<ruta PP> --await <id>", background: true, notify: true)`.
4. Entrega el id, o saluda una sola vez si eres joiner. Espera al operador.

Son cuatro llamadas. No leas otras referencias para esto.

## Despertar, drenar y rearmar

El fin del proceso de fondo despierta la sesión con un aviso `[IMPORTANT: Background process … (exit code N)]` cuyo `Output:` **ya trae el cuerpo drenado**. No ejecutes otro await para recuperar ese mismo mensaje. Si el aviso dice `first N characters cut`, lee el cuerpo completo con `process(action="log", session_id=…)`.

Relanza un único await de fondo (`background: true, notify: true`) para el siguiente lote antes de trabajar o responder. El mantenimiento sigue autorizado aunque el mensaje del peer no traiga trabajo asignado. Aplica el contrato de alcance al cuerpo.

Exit 3 sin correo significa keeper parado o canal cerrado: no rearmes hasta confirmar un keeper válido. Exit 124 sólo sale con `--wait`. No uses `notify` con patrones (`watch_patterns`) sobre `--watch`: Hermes los limita y los apaga si disparan de más; el await por lote es la receta.

## Cierre y propiedad

`"$PP" --close <id>` al acabar la colaboración. La correa cierra el canal cuando muere el proceso `hermes`. `/new` o `/resume` dentro del mismo proceso **no** cambian de dueño: el canal sigue vivo hasta cerrar o salir. No adoptes otro dueño sin encargo.

## Límites conocidos

- Sesiones del gateway (`hermes gateway run`) comparten el proceso: todas se ven como el mismo `hermes:<pid>`, así que la propiedad no las distingue y la correa dura lo que el gateway. Úsalo sólo con un canal por gateway o en modo degradado.
- `hermes -q` / one-shot no drena avisos de fondo: modo degradado.

## Modo degradado

Sin avisos de fondo: `"$PP" --await <id> --wait N` en primer plano cuando debas esperar. Sin keeper: `--listen <id> --wait N`. Informa que no hay despertar entre turnos.
