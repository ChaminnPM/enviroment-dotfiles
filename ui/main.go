// nui - UI minimalista para los dotfiles (bubbletea + lipgloss).
// Subcomandos compatibles con el subconjunto de gum usado por los scripts,
// mas step/clear/report para el flujo de instalacion.
package main

import (
	"fmt"
	"os"
)

var nuiVersion = "0.2.3"

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]

	switch cmd {
	case "style":
		if err := cmdStyle(args); err != nil {
			fmt.Fprintln(os.Stderr, "nui style:", err)
			os.Exit(1)
		}
	case "log":
		if err := cmdLog(args); err != nil {
			fmt.Fprintln(os.Stderr, "nui log:", err)
			os.Exit(1)
		}
	case "spin":
		cmdSpin(args) // sale con el codigo del comando
	case "input":
		cmdInput(args)
	case "confirm":
		cmdConfirm(args)
	case "choose":
		cmdChoose(args)
	case "pager":
		if err := cmdPager(args); err != nil {
			fmt.Fprintln(os.Stderr, "nui pager:", err)
			os.Exit(1)
		}
	case "banner":
		if err := cmdBanner(args); err != nil {
			fmt.Fprintln(os.Stderr, "nui banner:", err)
			os.Exit(1)
		}
	case "box":
		if err := cmdBox(args); err != nil {
			fmt.Fprintln(os.Stderr, "nui box:", err)
			os.Exit(1)
		}
	case "clear":
		clearScreen()
	case "report":
		cmdReport(args)
	case "steps":
		os.Exit(cmdSteps(args))
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

func usage(w *os.File) {
	fmt.Fprint(w, `nui - UI de instalacion (bubbletea)

Uso: nui <comando> [opciones]

Comandos:
  banner <linea>...                       banner centrado
  box [--color ok|err|warn|accent] [--align center] <lineas...>
  clear                                   limpia pantalla y scrollback
  report [--ok x] [--warn x] [--err x] [--info x] [--title t]
  steps run --plan <archivo|-> [--log-dir DIR] [--plain] [--title t]
                                          panel de pasos con ejecucion en vivo
  spin [--spinner s] [--titulo t] -- <cmd...>   spinner mientras corre cmd
  input [--prompt p] [--placeholder x] [--value v] [--password]
  confirm <pregunta>                      exit 0 si, exit 1 no
  choose [--header h] [--no-limit] [--height n] <opciones...>
  pager <archivo...>
  style [flags gum] <texto>               caja/estilo (subconjunto gum)
  log [--level info|warn|error|ok] <msg>
  version
`)
}
