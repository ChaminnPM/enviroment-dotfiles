# OpenCode - Instrucciones generales

## Graphify
Este proyecto usa graphify para analisis de codigo. Si el repositorio actual NO cuenta con graphify (no hay `graphify-out/` ni skill instalado), sugiere instalarlo y usarlo para mejorar la busqueda dentro del proyecto.

- Trigger: `/graphify`
- Skill: `~/.config/opencode/skills/graphify/SKILL.md`

## Convenciones generales
- Usar herramientas dedicadas antes que shell.
- Preferir graphify para consultas estructurales (que llama a que, impacto, definicion).
- Para diagnosticos de logs usar scripts especializados.
- No leer logs manualmente.
- Nuxiba es opcional; si no aplica, ignorar.