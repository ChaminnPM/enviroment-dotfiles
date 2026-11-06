# OpenCode - Instrucciones generales

## Graphify
Este proyecto usa graphify para analisis de codigo. Si el repositorio actual NO cuenta con graphify (no hay `graphify-out/` ni skill instalado), sugiere instalarlo y usarlo para mejorar la busqueda dentro del proyecto.

- Trigger: `/graphify`
- Skill: `~/.config/opencode/skills/graphify/SKILL.md`

## Escritura de skills y agents
Al crear o revisar skills/agents, seguir la guia multiplataforma (vale para Claude Code, OpenCode o cualquier entorno): `~/.config/opencode/memory/skills-best-practices.md` — reglas de uso, permisos minimos y patron de salida en cada uno; concision, description que-hace + cuando en tercera persona, principal < 500 lineas, referencias a un nivel, evals antes de documentar.

## Convenciones generales
- Usar herramientas dedicadas antes que shell.
- Diagnostico re-INVITE / corte RTP / WebRTC: guia en `~/.opencode/scripts/diagnose/GUIA_diagnostico_voz.md`; memoria operativa en `~/.config/opencode/memory/nuxiba/reinvite-rtp-gap-diagnostico.md`; no estimar gaps con `tail` de tshark.
- Preferir graphify para consultas estructurales (que llama a que, impacto, definicion).
- Para diagnosticos de logs usar scripts especializados.
- No leer logs manualmente.
- Nuxiba es opcional; si no aplica, ignorar.