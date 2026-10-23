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
- `config/opencode/`: config global (sin MCP figma).
- `agents/`: net-qa, react-qa, lua-qa.
- `skills/`: graphify, generate-test-cases, generate-tests, security-audit.
- `plugins/`: herdr-agent-state.js, usage-limits.
- `AGENTS.md`: instrucciones generales con graphify.

## Sincronizacion
- `bash scripts/sync.sh push` — sube cambios locales.
- `bash scripts/sync.sh pull` — baja cambios del repo.

## Requiere
- git, curl, node (nvm), python3, bash.
- herdr y oh-my-bash se instalan automaticamente.