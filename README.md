# enviroment-dotfiles (publico)

Configuracion portable de OpenCode para Linux/macOS.

## One-liner
```bash
curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.sh | bash
```

## Orden de ejecucion
1. Ejecutar el one-liner (pregunta si configurar identidad Git; Nuxiba es opcional).
2. Sincronizar:
   ```bash
   bash scripts/sync.sh pull
   ```

## Contenido publico
- `config/opencode/`: config global (sin MCP figma, sin contenido Nuxiba).
- `agents/`: net-qa, react-qa, lua-qa, analyze-webrtc-dumps.
- `skills/`: generate-test-cases, generate-tests, graphify (externa), security-audit (externa).
- `plugins/`: herdr-agent-state.js, usage-limits.
- `memory/skills-best-practices.md`: guia de escritura de skills/agents.
- `AGENTS.md`: instrucciones generales con graphify.

## Skills externas
- `graphify`: https://github.com/Graphify-Labs/graphify
- `security-audit`: https://github.com/cloudflare/security-audit-skill

Cada skill externa incluye `VERSION.json`. Para consultar/actualizar:
```bash
bash scripts/update-external-skills.sh check
bash scripts/update-external-skills.sh update
```

## Sincronizacion
- `bash scripts/sync.sh push` — sube solo assets publicos.
- `bash scripts/sync.sh pull` — baja solo assets publicos.
- Los assets privados (Nuxiba) se gestionan con `sync-private.sh` del repo privado.

## Requiere
- git, curl, bash, python3, node (nvm), npm, rsync, openssh-client, xdg-utils.
- gum (se instala automaticamente si falta).
- herdr y oh-my-bash se instalan automaticamente.

## Notas
- Los scripts usan `gum` para mejorar legibilidad y tienen fallback textual.
- `analyze-webrtc-dumps` es un **agente**, no una skill.
