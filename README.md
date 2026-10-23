# enviroment-dotfiles

Migracion de configuracion de OpenCode a Linux/macOS.

## Repositorios
- Publico: `ChaminnPM/enviroment-dotfiles`
- Privado: `ChaminnPM/enviroment-dotfiles-secrets`

## Orden de ejecucion (IMPORTANTE)

1. Clonar el repo publico:
   ```bash
   git clone git@github.com:ChaminnPM/enviroment-dotfiles.git
   ```
2. Ejecutar `bootstrap.sh` (pregunta si configurar identidad Git; Nuxiba es opcional):
   ```bash
   cd enviroment-dotfiles && bash bootstrap.sh
   ```
3. Sincronizar:
   ```bash
   bash scripts/sync.sh pull
   ```

## Sincronizacion entre maquinas
- `bash scripts/sync.sh push` — sube cambios locales al repo.
- `bash scripts/sync.sh pull` — baja cambios del repo al entorno.
- Antes de push/pull se verifican las llaves SSH.

## Contenido
- `config/opencode/`: config global (sin MCP figma).
- `agents/`: 8 agentes custom.
- `skills/`: analize_webrtc_dumps, graphify, generate-test-cases, generate-tests, security-audit.
- `plugins/`: herdr-agent-state.js, usage-limits.
- `memory/` (repo privado): reportes CenterWare y Reminder.

## Requiere
- git, curl, node (nvm), python3, bash.
- herdr se instala automaticamente via bootstrap.sh (curl -fsSL https://herdr.dev/install.sh | sh).
- oh-my-bash se instala automaticamente.