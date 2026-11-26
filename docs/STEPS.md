# Contrato de pasos (bash <-> PowerShell <-> nui)

Documento interno de mantenimiento: describe lo que comparten `bootstrap.sh`,
`bootstrap.ps1` y `nui`. Para instalar el entorno, ver el
[`README`](../README.md).

Los instaladores de Linux/WSL (`bootstrap.sh`) y de Windows (`bootstrap.ps1`)
comparten el mismo contrato con `nui`. Cambiar una de las tres columnas sin
cambiar las otras rompe la UX, `--only` y la documentacion.

## 1. Plan de pasos (JSON)

`nui steps run --plan <archivo>` recibe:

```json
{
  "title": "AGENTS ENVIRONMENT",
  "shell": "bash",
  "notes": ["Comandos: sync-dotfiles pull/push"],
  "steps": [
    {
      "title": "Dependencias base",
      "cmd": "bash '/tmp/nui-steps.XXXX/step-1.sh'",
      "argv": ["pwsh", "-NoProfile", "-File", "C:\\nui-steps\\step-01.ps1"],
      "optional": false,
      "interactive": false,
      "estimate": 45,
      "inputs": []
    }
  ]
}
```

| Campo | Que hace |
|---|---|
| `shell` | `bash` (default, Linux/WSL) o `pwsh` (Windows). Decide el interprete del fallback y el formato de los resultados de formulario. Un plan no mezcla los dos. |
| `cmd` | Cadena de comando. `nui` la ejecuta con `<shell> -c` / `<shell> -Command`. Se conserva por compatibilidad y para mostrar el comando. |
| `argv` | **Forma preferida**: argv literal, sin reinterpretacion. En Windows es obligatoria porque `C:\Users\John Doe\...` con espacios nunca debe pasar por un shell. |
| `optional` | Si el paso falla, se registra como aviso y la instalacion continua. |
| `interactive` | El paso recibe la terminal (cedida por el panel). No debe usarse dentro de un paso no interactivo. |
| `estimate` | Segundos estimados, solo para el progreso visual. |
| `inputs` | Formulario que el panel resuelve **antes** de ejecutar el paso. |

Validacion: `loadPlan` rechaza shells desconocidas, pasos sin `cmd` ni `argv`,
`inputs` sin nombre, `select` sin opciones y `show_if` que referencia un campo
no previo.

## 2. Directivas por stdout

Un paso habla con el panel escribiendo lineas en stdout:

| Directiva | Efecto |
|---|---|
| `##progress 45` | Porcentaje del paso en curso. |
| `##log texto` | Linea limpia en el panel (no se guarda como error). |
| `##title texto` | Renombra el paso en vivo. |
| `##warn texto` | Marca el paso como aviso y continua. |
| `##confirm <id> <pregunta>` | Pregunta en el panel; bloquea hasta la respuesta. |

Cualquier otra linea se muestra como salida normal del paso y se conserva en el
log. `##warn` dentro de un paso `optional` es el camino normal para "fallo
decente" (fuente no descargable, paquete ausente, etc.).

## 3. Variables de entorno del runner

| Variable | La pone | La lee |
|---|---|---|
| `NUI_STATE_DIR` | runner | pasos y `nui` |
| `NUI_STEP_RESULT` | runner | paso (ruta del archivo de resultados) |
| `NUI_CONFIRM_FILE`/`confirm-<id>.env` | `nui` al responder | paso (via el helper) |
| `NUI_ENV_FILE` | runner | paso (persistencia de PATH) |
| `NUI_PLAIN` | runner (modo texto) | helpers de UI |
| `NUI_NONINTERACTIVE`, `NUI_DRY_RUN`, `NUI_NO_COLOR`, `NUI_ONLY` | usuario | runner y helpers |
| `NUI_BASE_URL`, `UI_BIN`, `NUI_VERSION` | usuario | instalacion de `nui` |

## 4. Formato de resultados de formulario

El mismo valor, serializado segun `shell`:

```bash
# result-07.env  (bash; el paso hace `. "$NUI_STEP_RESULT"`)
p_name='Chaminn'
extras='bat
eza'
```

```powershell
# result-07.ps1  (pwsh; el paso hace `. $env:NUI_STEP_RESULT`)
$p_name = 'Chaminn'
$extras = 'bat
eza'
```

Escapado: `'\''` en bash, `''` en PowerShell. Los valores multineales
(`select ... many`) se guardan separados por `\n` en ambos.

Un campo oculto por `show_if` se escribe **vacio**: nunca debe heredar el valor
de una variable de entorno del paso.

## 5. Confirmaciones dentro de un paso

`##confirm <id> <pregunta>` hace que el panel escriba la respuesta en
`$NUI_STATE_DIR/confirm-<id>.env` como `NUI_CONFIRM_ANSWER=true|false`. El paso
espera el archivo (max 5 min) y decide. Esto evita lanzar una segunda TUI de
bubbletea sobre la misma terminal.

En modo texto (`NUI_PLAIN=1`) el helper pregunta directamente por la consola
(`/dev/tty` en POSIX, `CONIN$` en Windows).

## 6. Titulos de paso

Los titulos son identificadores de cara al usuario: `--only <texto>` filtra por
eles y la documentacion los cita. Cualquier cambio exige actualizar
`bootstrap.sh`, `bootstrap.ps1`, `README.md` y `docs/`.

Linux/WSL y Windows comparten titulo cuando el paso es equivalente. El unico
nombre que difiere a proposito es el del terminal:

| Linux/WSL | WSL sobre Windows | Windows nativo |
|---|---|---|
| `Alacritty (opcional)` | `Alacritty (opcional)` | `Windows Terminal (tema)` |

## 7. Reglas de seguridad del runner

- Ningun dato del usuario se interpola en una cadena de shell: argv literal o
  `ui_logged_argv` / `Invoke-Native`.
- `eval` / `Invoke-Expression` no se usan sobre entrada externa.
- Logs y resultados se crean `0600` dentro de directorios `0700`
  (en Windows: ACL restringida al usuario).
- `nui` se verifica con `bin/SHA256SUMS` antes de ejecutarse.
- La cancelacion mata el arbol de procesos del paso (grupos POSIX / Job Object
  + `taskkill /T`).
