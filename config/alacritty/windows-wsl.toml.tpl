# Overlay para Alacritty corriendo en Windows y lanzando WSL.
# Los valores se derivan del entorno en apply-theme.sh; se pueden fijar con
# THEME_WSL_WORKDIR, THEME_WSL_DISTRO y THEME_WSL_HOME.

[general]
working_directory = '{{THEME_WSL_WORKDIR}}'

[terminal.shell]
program = "wsl.exe"
args = ["-d", "{{THEME_WSL_DISTRO}}", "--cd", "{{THEME_WSL_HOME}}"]
