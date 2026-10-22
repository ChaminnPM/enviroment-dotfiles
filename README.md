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
2. Ejecutar `scripts/setup-git-identity.sh` PRIMERO:
   - Genera llaves SSH para personal (GitHub) y Nuxiba (Bitbucket).
   - Muestra las claves publicas -> agregalas a GitHub/Bitbucket.
   - Prueba conexiones SSH. NO continuar hasta que ambas pasen.
3. Ejecutar `bootstrap.sh`:
   ```bash
   cd enviroment-dotfiles && bash bootstrap.sh
   ```
4. Sincronizar:
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
- herdr instalado manualmente si se usa.