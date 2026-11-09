package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ", ") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// cmdReport: reporte final de instalacion. Sale con codigo 1 si hay errores.
func cmdReport(args []string) {
	var oks, warns, errs, infos multiFlag
	title := "REPORTE FINAL"

	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() string {
			i++
			if i >= len(args) {
				return ""
			}
			return args[i]
		}
		switch a {
		case "--ok":
			oks.Set(next())
		case "--warn":
			warns.Set(next())
		case "--err":
			errs.Set(next())
		case "--info":
			infos.Set(next())
		case "--title":
			title = next()
		default:
			fmt.Fprintf(os.Stderr, "nui report: opcion no soportada: %s\n", a)
		}
	}

	printReport(title, oks, warns, errs, infos)
	if len(errs) > 0 {
		os.Exit(1)
	}
}

// printReport imprime el reporte final y devuelve true si hay errores.
func printReport(title string, oks, warns, errs, infos []string) bool {
	clearScreen()

	width := termWidth()
	fmt.Println(lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colAccent).
		Align(lipgloss.Center).
		Width(width).
		Padding(0, 2).
		Bold(true).
		Foreground(colWhite).
		Render(title))

	section := func(label string, n int, color lipgloss.TerminalColor, items []string, symbol string) {
		if n == 0 {
			return
		}
		head := lipgloss.NewStyle().Bold(true).Foreground(color).Render(
			fmt.Sprintf("%s (%d)", label, n))
		fmt.Printf("\n  %s\n", head)
		symStyle := lipgloss.NewStyle().Bold(true).Foreground(color)
		for _, it := range items {
			fmt.Printf("  %s %s\n", symStyle.Render(symbol), it)
		}
	}

	section("INSTALADO", len(oks), colGreen, oks, "✓")
	section("AVISOS", len(warns), colYellow, warns, "!")
	section("ERRORES", len(errs), colRed, errs, "✗")

	foot := lipgloss.NewStyle().Foreground(colDim)
	if len(infos) > 0 {
		for _, in := range infos {
			fmt.Printf("\n  %s\n", foot.Render(in))
		}
	}
	counts := fmt.Sprintf("%d ok · %d aviso · %d error",
		len(oks), len(warns), len(errs))
	fmt.Printf("\n  %s\n", foot.Render(counts))

	return len(errs) > 0
}
