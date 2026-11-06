# Guia universal para escribir Skills y Agents (multiplataforma)

Aplica a **cualquier entorno** que cargue instrucciones en contexto: Claude Code,
OpenCode, y cualquier agente con herramientas equivalentes. Los principios son del
modelo, no de la plataforma. Al materializar en un entorno concreto, ver
"Adaptaciones por plataforma" al final.

Fuente principal: https://platform.claude.com/docs/es/agents-and-tools/agent-skills/best-practices

## 1. Principios fundamentales

1. **Concision es clave.** La ventana de contexto es compartida. Solo se precargan
   `name` + `description`; el cuerpo se carga cuando la tarea se vuelve relevante.
   Preguntarme ante cada parte: "¿el modelo ya sabe esto?", "¿este parrafo justifica
   sus tokens?".
2. **Grados de libertad apropiados** (ajustar a la fragilidad de la tarea):
   - Alta libertad (texto): tareas con muchos enfoques validos (code review).
   - Media (pseudocodigo/scripts con params): patron preferido, variacion aceptable.
   - Baja libertad (script exacto, sin flags): operaciones fragiles/secuencia exacta
     (migraciones, validadores). Analogia: puente estrecho con precipicios = barreras
     explicitas; campo abierto = direccion general.
3. **Probar con todos los modelos** que se usaran (los rapidos necesitan mas guia,
   los potentes menos explicacion).

## 2. Frontmatter portatil

- `name`: max 64 chars, solo minusculas/numeros/guiones, sin palabras reservadas
  `anthropic`/`claude`.
- `description`: max 1024 chars, **en tercera persona**, incluye QUE hace y CUANDO
  usarla (disparadores/terminos clave). Es lo unico que decide la seleccion entre
  100+ skills. Ejemplo: "Extract text and tables from PDF files... Use when working
  with PDF files or when the user mentions PDFs, forms...".
- Nombres: gerundio (`processing-pdfs`), nominal (`pdf-processing`) o accion
  (`process-pdfs`); evitar vagos (`helper`, `docs`) e inconsistentes.
- **Descriptions con triggers solapados**: si dos skills pueden competir por la
  misma peticion, poner exclusión mutua explicita en ambas ("para X usa Y; para Z
  usa W").
- En agentes: `description` es lo que el orquestador ve para elegir subagente —
  incluir el dominio y el disparador.

## 3. Tres pilares de cada skill/agent (obligatorios)

1. **Reglas de uso**: cuando activar, cuando NO, prerequisitos, gates de aprobacion,
   que hacer si falta un recurso (reportar y detenerse, nunca inventar).
2. **Permisos**: minimo privilegio. Declarar herramientas necesarias (frontmatter)
   Y reglas en el cuerpo ("solo lectura", "nunca modifica codigo de produccion",
   "sin red"). Los permisos del frontmatter no sustituyen las reglas del cuerpo.
3. **Patron de salida**: formato exacto y en orden (esqueleto en bloque de codigo
   cuando el formato importa). El modelo improvisa menos con una plantilla que con
   una descripcion.

## 4. Divulgacion progresiva

- Cuerpo del archivo principal **< 500 lineas**; si se acerca, dividir.
- Referencias **a un nivel de profundidad** desde el archivo principal.
- Archivos de referencia > 100 lineas: tabla de contenidos al inicio.
- Nombres de archivo descriptivos, rutas con barras diagonales (`scripts/run.py`).
- Scripts: **ejecutar**, no leer; distinguir "ejecuta X" de "consulta X"; declarar
  paquetes requeridos (no asumir instalados).

## 5. Flujos de trabajo y feedback

- Tareas complejas = pasos claros y secuenciales; checklist copiable que el agente
  marca a medida que avanza.
- Ciclos de retroalimentacion: validar -> corregir -> repetir; solo avanzar cuando
  pasa. Patron planificar-validar-ejecutar con archivo intermedio verificable para
  cambios por lote/destructivos.
- **Reglas de parada** (estilo pair programming): detenerse si hay decision de
  diseno fuera del plan, si pasar un test exige cambiar/saltar/borrar un test, si
  N intentos consecutivos fallan, o si se excede el tamano de un paso.
- Plantillas de salida: rigidas para formatos estrictos, flexibles cuando la
  adaptacion ayuda. Ejemplos concretos pares entrada/salida > descripciones.
- Nada sensible al tiempo (fechas/versions) -> seccion "patrones antiguos".
- Terminologia consistente; un default + escape hatch en vez de 5 opciones.

## 6. Agents (system prompt = cuerpo del archivo)

- Frontmatter: `description` (disparador), `mode`, `color`, `permissions`.
  **Un solo formato de frontmatter por archivo** (mezclar V1 y V2 invalida campos).
- Permisos en lista ordenada `[{action, resource, effect}]`; gana la ultima
  regla que matchea -> reglas especificas primero, `*` al final.
  Acciones tipicas: `read`, `glob`, `grep`, `edit`, `shell`, `webfetch`, `websearch`,
  `skill`, `subagent`.
- Un agente diagnostico/solo-lectura: `edit: deny`, `web*: deny` si no los usa;
  escrituras solo via salida del script y solo si el usuario lo pide.
- El cuerpo debe empezar con reglas de uso y terminar con el patron de salida.
- `temperature` en el frontmatter NO tiene efecto en OpenCode V2 (va en una
  model variant); no ponerla por costumbre.

## 7. Evaluacion e iteracion

- **Crear evaluaciones ANTES** de documentar: brechas sin skill -> 3 escenarios ->
  linea base -> instrucciones minimas -> iterar.
- Ciclo A (refina la skill) / B (la usa en tarea real) / observar -> corregir.
  Observar: rutas de lectura inesperadas, referencias ignoradas, archivos nunca usados.
- Minimo 3 evaluaciones; probar con escenarios reales y feedback del equipo.

## 8. Checklist rapida

- [ ] Description: que hace + cuando usarla, tercera persona, sin triggers solapados
- [ ] Reglas de uso (incluido "cuando NO" y que hacer si falta un recurso)
- [ ] Permisos minimos declarados (frontmatter + cuerpo)
- [ ] Patron de salida con esqueleto
- [ ] Principal < 500 lineas, referencias a 1 nivel, TOC si > 100 lineas
- [ ] Reglas de parada si el flujo escribiente/largo
- [ ] Sin info sensible al tiempo, terminologia consistente, ejemplos concretos
- [ ] Scripts resuelven errores, sin valores magicos, dependencias declaradas
- [ ] 3 evaluaciones + prueba en escenarios reales

## 9. Antipatrones

- Explicar lo que el modelo ya sabe; rutas con barras invertidas; ofrecer 5
  librerias en vez de un default; anidar referencias; workflows gigantes en un
  solo archivo; skills que solo reescriben lo que ya dice otra skill/instruccion;
  permisos amplios "por si acaso"; formatos de salida que dependen de la memoria
  del modelo en vez de una plantilla.

---

# Adaptaciones por plataforma

## Claude Code / Agent Skills (Anthropic)

- Frontmatter: `name` (64 chars, minusculas/guiones), `description` (1024 chars),
  `allowed-tools` (restringe herramientas de la skill), `disable-model-invocation: true`
  (solo invocacion manual por el usuario), `license`, `compatibility`.
- Ubicacion: `.claude/skills/<id>/SKILL.md` o `~/.claude/skills/`.
- `$ARGUMENTS` / `$1..$N`: solo en **commands** (`.claude/commands/*.md`), no en
  skills. Si una skill viene convertida de un command, no depender de `$ARGUMENTS`:
  escribir "el objetivo se recibe en la invocacion; si falta, preguntar".
- Los scripts se ejecutan en el sandbox de Code Execution; listar paquetes requeridos.

## OpenCode (V2)

- ID = nombre del **directorio** (`^[a-z0-9]+(-[a-z0-9]+)*$` recomendado); el
  `name` del frontmatter es solo etiqueta de display. Renombrar la carpeta cambia
  el ID y rompe referencias `@id` — decidir antes de publicar.
- Sin `description` la skill **no se anuncia**. `disable-model-invocation: true` o
  `metadata.opencode/autoinvoke: false` la ocultan del modelo (invocacion manual).
- `$ARGUMENTS` solo en **commands** (`~/.config/opencode/commands/*.md`); en skills
  llega como texto literal.
- `allowed-tools` en skills **se ignora** (no restringe nada): las reglas de
  permisos efectivas van en el cuerpo y en los `permissions` del agente.
- Agents: frontmatter V2 (`permissions` lista, `system` via cuerpo, `disabled`,
  `steps`, `hidden`, `color`, `mode`). Frontmatter V1 (`permission` mapa,
  `temperature`, `name`, `tools`) esta deprecado: se traduce automaticamente pero
  `temperature` no tiene efecto. Si el archivo usa campos V2, los V1 se ignoran con
  warning — **convertir de una vez, nunca mezclar**.
- Permisos: gana la ultima regla; acciones `shell` (antes `bash`), `edit` (antes
  `write`/`patch`), `subagent` (antes `task`).
- Descubrimiento de instrucciones: `AGENTS.md` global + `instructions` en config.

## Regla general al migrar

Antes de depender de un campo de frontmatter, verificarlo en la documentacion de
ESE entorno; tratar todo lo portatil (cuerpo markdown, descripciones, reglas,
patrones de salida) como el activo durable y el frontmatter como adaptador.
