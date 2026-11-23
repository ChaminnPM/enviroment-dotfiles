#!/usr/bin/env bash
# theme.sh - carga del tema canonico, deteccion de entorno, fuente Nerd y
# renderizado de plantillas. Lo consumen bootstrap.sh y apply-theme.sh.
# Los mensajes usan el protocolo ##log / ##warn del panel de nui.

# --- localizacion del archivo de tema -------------------------------------
theme_env_file() {
  local f
  for f in "${THEME_ENV_FILE:-}" \
           "${REPO_DIR:-}/config/theme/dracula.env" \
           "${OPENCODE_DIR:-}/theme/dracula.env" \
           "$HOME/.config/enviroment-dotfiles/theme/dracula.env"; do
    if [ -n "$f" ] && [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# --- carga de tokens -------------------------------------------------------
theme_load_env() {
  local f defaults
  f="$(theme_env_file)" || {
    printf '##warn No se encontro config/theme/dracula.env\n'
    return 1
  }

  defaults='THEME_NAME=dracula
THEME_BG=#282a36
THEME_BLACK_DARKER=#21222c
THEME_CURRENT=#44475a
THEME_FG=#f8f8f2
THEME_COMMENT=#6272a4
THEME_RED=#ff5555
THEME_GREEN=#50fa7b
THEME_ORANGE=#ffb86c
THEME_YELLOW=#f1fa8c
THEME_PURPLE=#bd93f9
THEME_PINK=#ff79c6
THEME_CYAN=#8be9fd
THEME_BRIGHT_BLACK=#6272a4
THEME_BRIGHT_RED=#ff6e6e
THEME_BRIGHT_GREEN=#69ff94
THEME_BRIGHT_YELLOW=#ffffa5
THEME_BRIGHT_BLUE=#d6acff
THEME_BRIGHT_MAGENTA=#ff92df
THEME_BRIGHT_CYAN=#a4ffff
THEME_BRIGHT_WHITE=#ffffff
THEME_FONT_FAMILY=JetBrainsMono Nerd Font
THEME_FONT_SIZE=10.0
THEME_NERD_VERSION=v3.4.0
THEME_NERD_REPO_URL=https://github.com/ryanoasis/nerd-fonts
THEME_NERD_ASSET=JetBrainsMono.zip
THEME_OMB_THEME=vscode
THEME_EZA_COLORS=
THEME_FZF_OPTS='

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local key="${line%%=*}" val="${line#*=}"
    [ -z "${!key+x}" ] && export "$key=$val"
  done <<< "$defaults"

  # shellcheck disable=SC1090
  . "$f"
  export THEME_NAME THEME_BG THEME_BLACK_DARKER THEME_CURRENT THEME_FG THEME_COMMENT
  export THEME_RED THEME_GREEN THEME_ORANGE THEME_YELLOW THEME_PURPLE
  export THEME_PINK THEME_CYAN THEME_FONT_FAMILY THEME_FONT_SIZE
  export THEME_NERD_VERSION THEME_NERD_REPO_URL THEME_NERD_ASSET
  export THEME_OMB_THEME THEME_EZA_COLORS THEME_FZF_OPTS
  export THEME_BRIGHT_BLACK THEME_BRIGHT_RED THEME_BRIGHT_GREEN
  export THEME_BRIGHT_YELLOW THEME_BRIGHT_BLUE THEME_BRIGHT_MAGENTA
  export THEME_BRIGHT_CYAN THEME_BRIGHT_WHITE
  return 0
}

# --- deteccion de entorno --------------------------------------------------
theme_detect_env() {
  if [ -n "${DOTFILES_ENV:-}" ]; then printf '%s' "$DOTFILES_ENV"; return 0; fi
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux)
      if [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        printf 'windows-wsl'
      else
        printf 'linux'
      fi
      ;;
    *) printf 'linux' ;;
  esac
}

# --- fuente Nerd -----------------------------------------------------------
theme_font_installed() {
  command -v fc-match >/dev/null 2>&1 || return 1
  local match
  match="$(fc-match "$THEME_FONT_FAMILY" 2>/dev/null || true)"
  printf '%s' "$match" | grep -Fqi "$THEME_FONT_FAMILY"
}

# fontconfig puede no ver la fuente aunque los TTF esten en disco (cache
# desactualizada, HOME distinto durante fc-cache, sesion sin fontconfig). En ese
# caso no debe abortarse toda la instalacion: basta un aviso.
theme_font_files_present() {
  local dest="$HOME/.local/share/fonts" f
  for f in "$dest"/JetBrainsMono*NerdFont*.ttf "$dest"/JetBrainsMono*NerdFont*.otf; do
    [ -f "$f" ] && return 0
  done
  return 1
}

theme_font_ok() {
  if theme_font_installed; then return 0; fi
  if theme_font_files_present; then
    printf '##warn La fuente esta en disco pero fontconfig no la ve todavia; ejecuta fc-cache -f\n'
    return 0
  fi
  return 1
}

theme_write_manifest() {
  local dir="$HOME/.config/enviroment-dotfiles" out
  mkdir -p "$dir" 2>/dev/null || return 0
  out="$dir/theme.json"
  python3 - "$out" <<'PY' 2>/dev/null || true
import datetime, json, os, sys
data = {
    "theme": os.environ.get("THEME_NAME", "dracula"),
    "font": os.environ.get("THEME_FONT_FAMILY", ""),
    "nerd_version": os.environ.get("THEME_NERD_VERSION", ""),
    "applied": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

theme_ensure_font() {
  if theme_font_installed; then
    printf '##log Fuente %s ya instalada\n' "$THEME_FONT_FAMILY"
    theme_write_manifest
    return 0
  fi
  if theme_font_files_present; then
    printf '##log TTFs presentes; refrescando cache de fontconfig\n'
    if command -v fc-cache >/dev/null 2>&1; then
      fc-cache -f "$HOME/.local/share/fonts" >/dev/null 2>&1 || true
      fc-cache -f >/dev/null 2>&1 || true
    fi
    if theme_font_ok; then
      theme_write_manifest
      return 0
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    printf '##warn curl no disponible; no se pudo instalar la fuente\n'
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf '##warn python3 no disponible; no se pudo extraer la fuente\n'
    return 1
  fi

  local tmp zip dest url
  tmp="$(mktemp -d)"
  zip="$tmp/font.zip"
  dest="$HOME/.local/share/fonts"
  url="${THEME_NERD_REPO_URL}/releases/download/${THEME_NERD_VERSION}/${THEME_NERD_ASSET}"

  printf '##log Descargando %s\n' "$url"
  if ! curl -fsSL --retry 3 --max-time 300 "$url" -o "$zip"; then
    printf '##warn No se pudo descargar la fuente desde %s\n' "$url"
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p "$dest"
  if ! python3 - "$zip" "$dest" <<'PY'
import os, sys, zipfile
src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    names = [n for n in z.namelist()
             if n.lower().endswith((".ttf", ".otf")) and not n.startswith("__MACOSX")]
    for n in names:
        target = os.path.join(dest, os.path.basename(n))
        with z.open(n) as s, open(target, "wb") as f:
            while True:
                chunk = s.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
PY
  then
    printf '##warn No se pudo extraer la fuente (zip corrupto?)\n'
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  printf '##log TTFs extraidos en %s\n' "$dest"

  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$dest" >/dev/null 2>&1 || true
    fc-cache -f >/dev/null 2>&1 || true
  else
    printf '##log fontconfig no disponible; TTFs copiados a %s\n' "$dest"
  fi

  # La cache puede tardar un instante en propagarse: reintentar antes de dar
  # por fallido el paso (antes un solo fc-match abortaba toda la instalacion).
  local attempt
  for attempt in 1 2 3; do
    if theme_font_installed; then
      printf '##log Fuente %s instalada (%s)\n' "$THEME_FONT_FAMILY" "$THEME_NERD_VERSION"
      theme_write_manifest
      return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 1 2>/dev/null || true
  done

  if theme_font_files_present; then
    printf '##warn TTFs instalados en %s pero fontconfig no los ve; ejecuta fc-cache -f\n' "$dest"
    theme_write_manifest
    return 0
  fi
  printf '##warn La fuente no es visible para fontconfig; revisa %s\n' "$dest"
  return 1
}

# --- plantillas ------------------------------------------------------------
# theme_render_toml <plantilla> <salida|->  (usa variables THEME_* exportadas)
theme_render_toml() {
  local tpl="$1" out="$2"
  [ -f "$tpl" ] || { printf '##warn Plantilla no encontrada: %s\n' "$tpl"; return 1; }
  if [ "$out" = "-" ]; then
    python3 - "$tpl" <<'PY'
import os, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(r"\{\{([A-Z0-9_]+)\}\}", lambda m: os.environ.get(m.group(1), m.group(0)), src)
sys.stdout.write(out)
PY
  else
    mkdir -p "$(dirname "$out")"
    python3 - "$tpl" "$out" <<'PY'
import os, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = re.sub(r"\{\{([A-Z0-9_]+)\}\}", lambda m: os.environ.get(m.group(1), m.group(0)), src)
open(sys.argv[2], "w", encoding="utf-8").write(out)
PY
  fi
}
