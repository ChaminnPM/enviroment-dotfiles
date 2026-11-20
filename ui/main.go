// nui - UI minimalista para los dotfiles (bubbletea + lipgloss).
// Subcomandos compatibles con el subconjunto de gum usado por los scripts,
// mas step/clear/report para el flujo de instalacion.
//
// Solo Linux y WSL: el panel usa grupos de procesos POSIX y /dev/tty.
// Ver docs/PLATFORMS.md.
package main

import (
	"fmt"
	"os"
)

var nuiVersion = "0.2.8"

func main() {
	args := stripNoColor(os.Args[1:])
	if len(args) < 1 {
		usage(os.Stderr)
		os.Exit(2)
	}
	cmd, cmdArgs := args[0], args[1:]

	switch cmd {
	case "style":
		if err := cmdStyle(cmdArgs); err != nil {
			fmt.Fprintln(os.Stderr, "nui style:", err)
			os.Exit(1)
		}
	case "log":
		if err := cmdLog(cmdArgs); err != nil {
			fmt.Fprintln(os.Stderr, "nui log:", err)
			os.Exit(1)
		}
	case "spin":
		cmdSpin(cmdArgs) // sale con el codigo del comando
	case "input":
		cmdInput(cmdArgs)
	case "confirm":
		cmdConfirm(cmdArgs)
	case "choose":
		cmdChoose(cmdArgs)
	case "pager":
		if err := cmdPager(cmdArgs); err != nil {
			fmt.Fprintln(os.Stderr, "nui pager:", err)
			os.Exit(1)
		}
	case "banner":
		if err := cmdBanner(cmdArgs); err != nil {
			fmt.Fprintln(os.Stderr, "nui banner:", err)
			os.Exit(1)
		}
	case "box":
		if err := cmdBox(cmdArgs); err != nil {
			fmt.Fprintln(os.Stderr, "nui box:", err)
			os.Exit(1)
		}
	case "clear":
		clearScreen()
	case "report":
		cmdReport(cmdArgs)
	case "steps":
		os.Exit(cmdSteps(cmdArgs))
	case "version", "--version", "-v":
		fmt.Println("nui " + nuiVersion)
	case "help", "--help", "-h":
		usage(os.Stdout)
	default:
		fmt.Fprintf(os.Stderr, "nui: comando desconocido: %s\n", cmd)
		usage(os.Stderr)
		os.Exit(2)
	}
}

// stripNoColor elimina --no-color (antes del separador `--`) y desactiva el
// color cuando NO_COLOR esta definido. Asi `nui spin -- cmd --no-color` sigue
// pasando el flag al comando hijo.
func stripNoColor(args []string) []string {
	out := make([]string, 0, len(args))
	disable := os.Getenv("NO_COLOR") != "" || os.Getenv("NUI_NO_COLOR") == "1"
	afterSep := false
	for _, a := range args {
		if a == "--" {
			afterSep = true
			out = append(out, a)
			continue
		}
		if !afterSep && a == "--no-color" {
			disable = true
			continue
		}
		out = append(out, a)
	}
	if disable {
		disableColor()
	}
	return out
}

func usage(w *os.File) {
	fmt.Fprint(w, `nui - UI de instalacion (bubbletea)

Uso: nui [--no-color] <comando> [opciones]

Comandos:
  banner <linea>...                       banner centrado
  box [--color ok|err|warn|accent] [--align center] <lineas...>
  clear                                   limpia pantalla y scrollback
  report [--ok x] [--warn x] [--err x] [--info x] [--title t]
  steps run --plan <archivo|-> [--log-dir DIR] [--plain] [--non-interactive] [--title t]
                                          panel de pasos con ejecucion en vivo
  spin [--spinner s] [--titulo t] -- <cmd...>   spinner mientras corre cmd
  input [--prompt p] [--placeholder x] [--value v] [--password] [--no-echo]
                                          sin TTY lee stdin y escribe el valor en stdout
                                          (p. ej. PW=$(nui input --password)); --no-echo
                                          (solo sin TTY) lo lee pero no imprime el valor
  confirm <pregunta>                      exit 0 si, exit 1 no
  choose [--header h] [--no-limit] [--height n] <opciones...>
  pager <archivo...>
  style [flags gum] <texto>               caja/estilo (subconjunto gum)
  log [--level info|warn|error|ok] <msg>
  version

Variables: NO_COLOR=1 desactiva color (igual que --no-color).

Solo Linux y WSL. Ver docs/PLATFORMS.md.
`)
}
