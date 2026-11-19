# Generado por scripts/apply-theme.sh desde config/theme/dracula.env.
# Tema: {{THEME_NAME}}. No editar a mano: se regenera en cada instalacion.
# Referencia: https://github.com/alacritty/alacritty/blob/master/extra/alacritty.toml

[general]
live_config_reload = true

[font]
size = {{THEME_FONT_SIZE}}

[font.normal]
family = "{{THEME_FONT_FAMILY}}"

[font.bold]
family = "{{THEME_FONT_FAMILY}}"
style = "Bold"

[font.italic]
family = "{{THEME_FONT_FAMILY}}"
style = "Italic"

[font.bold_italic]
family = "{{THEME_FONT_FAMILY}}"
style = "Bold Italic"

[colors.primary]
background = '{{THEME_BG}}'
foreground = '{{THEME_FG}}'

[colors.normal]
black   = '{{THEME_BLACK_DARKER}}'
red     = '{{THEME_RED}}'
green   = '{{THEME_GREEN}}'
yellow  = '{{THEME_YELLOW}}'
blue    = '{{THEME_PURPLE}}'
magenta = '{{THEME_PINK}}'
cyan    = '{{THEME_CYAN}}'
white   = '{{THEME_FG}}'

[colors.bright]
black   = '{{THEME_BRIGHT_BLACK}}'
red     = '{{THEME_BRIGHT_RED}}'
green   = '{{THEME_BRIGHT_GREEN}}'
yellow  = '{{THEME_BRIGHT_YELLOW}}'
blue    = '{{THEME_BRIGHT_BLUE}}'
magenta = '{{THEME_BRIGHT_MAGENTA}}'
cyan    = '{{THEME_BRIGHT_CYAN}}'
white   = '{{THEME_BRIGHT_WHITE}}'

[colors.selection]
text       = 'CellForeground'
background = '{{THEME_CURRENT}}'

[colors.cursor]
cursor = '{{THEME_PURPLE}}'
