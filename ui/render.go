package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"
)

// Paleta: indigo GitHub-like + estados.
var (
	colAccent = lipgloss.Color("#7B7FE6")
	colWhite  = lipgloss.Color("#FFFFFF")
	colDim    = lipgloss.Color("#6C7086")
	colGreen  = lipgloss.Color("#A6E3A1")
	colRed    = lipgloss.Color("#F38BA8")
	colYellow = lipgloss.Color("#F9E2AF")
)

func isTTY(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

func termWidth() int {
	if isTTY(os.Stdout) {
		if w, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && w > 0 {
			return w
		}
	}
	if w, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && w > 0 {
		return w
	}
	return 80
}

// termGetSize devuelve ancho/alto de la terminal del descriptor dado.
func termGetSize(fd int) (int, int, error) {
	w, h, err := term.GetSize(fd)
	if err != nil {
		return 0, 0, err
	}
	return w, h, nil
}

// clearScreen limpia pantalla y scrollback (ESC[3J) en TTY.
func clearScreen() {
	if os.Getenv("NUI_NO_CLEAR") == "1" {
		return
	}
	if !isTTY(os.Stdout) {
		return
	}
	fmt.Fprint(os.Stdout, "\033[3J\033[2J\033[H")
}

func parseColor(s string) lipgloss.TerminalColor {
	s = strings.TrimSpace(s)
	if s == "" {
		return colWhite
	}
	// termenv interpreta "212" como ANSI256, "#rrggbb" y nombres basicos.
	if n, err := strconv.Atoi(s); err == nil && n >= 0 && n <= 15 {
		return lipgloss.ANSIColor(n)
	}
	return lipgloss.Color(s)
}

// parseInts convierte "1 0" / "1 2 3 4" a enteros para Margin/Padding.
func parseInts(s string) []int {
	var out []int
	for _, f := range strings.Fields(s) {
		if n, err := strconv.Atoi(f); err == nil {
			out = append(out, n)
		}
	}
	return out
}

func namedColor(name string) lipgloss.TerminalColor {
	switch name {
	case "ok", "green":
		return colGreen
	case "err", "red":
		return colRed
	case "warn", "yellow":
		return colYellow
	case "accent", "indigo":
		return colAccent
	case "dim":
		return colDim
	case "white":
		return colWhite
	}
	return parseColor(name)
}

func borderByName(name string) lipgloss.Border {
	switch name {
	case "rounded":
		return lipgloss.RoundedBorder()
	case "double":
		return lipgloss.DoubleBorder()
	case "thick":
		return lipgloss.ThickBorder()
	case "hidden":
		return lipgloss.HiddenBorder()
	default:
		return lipgloss.NormalBorder()
	}
}

func alignByName(a string) lipgloss.Position {
	switch a {
	case "center":
		return lipgloss.Center
	case "right":
		return lipgloss.Right
	default:
		return lipgloss.Left
	}
}

// bannerBox: caja rounded, borde acento, line1 bold blanco, resto dim, centradas.
func bannerBox(width, padV int, lines []string) string {
	var content []string
	for i, l := range lines {
		if i == 0 {
			content = append(content, lipgloss.NewStyle().Bold(true).Foreground(colWhite).Render(l))
		} else {
			content = append(content, lipgloss.NewStyle().Foreground(colDim).Render(l))
		}
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colAccent).
		Align(lipgloss.Center).
		Width(width).
		Padding(padV, 2).
		Render(strings.Join(content, "\n"))
}

// cmdBanner: banner centrado con padding tipico (sync, identidad, etc).
func cmdBanner(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("falta el texto")
	}
	fmt.Println(bannerBox(termWidth(), 1, args))
	return nil
}

// cmdStep: limpia pantalla y pinta el banner compacto del paso (<=6 lineas).
func cmdStep(args []string) error {
	noClear := false
	var rest []string
	for _, a := range args {
		if a == "--no-clear" {
			noClear = true
			continue
		}
		rest = append(rest, a)
	}
	if len(rest) == 0 {
		return fmt.Errorf("falta el titulo del paso")
	}
	if !noClear {
		clearScreen()
	}
	fmt.Println(bannerBox(termWidth(), 0, rest))
	return nil
}

// cmdBox: caja de contenido (resumen, errores, avisos).
func cmdBox(args []string) error {
	color := "accent"
	align := "left"
	width := 0
	var rest []string
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
		case "--color":
			color = next()
		case "--align":
			align = next()
		case "--width":
			width, _ = strconv.Atoi(next())
		case "--":
			rest = append(rest, args[i+1:]...)
			i = len(args)
		default:
			rest = append(rest, a)
		}
	}
	if len(rest) == 0 {
		return fmt.Errorf("falta el texto")
	}
	st := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(namedColor(color)).
		Padding(1, 2).
		Align(alignByName(align))
	if width > 0 {
		st = st.Width(width)
	}
	fmt.Println(st.Render(strings.Join(rest, "\n")))
	return nil
}

// cmdStyle: subconjunto de gum style.
func cmdStyle(args []string) error {
	var fg, bg, bfg, border, align, margin, padding string
	var width, height int
	var bold, italic, underline, strike, dim, reverse bool
	var text []string

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
		case "--foreground", "-f":
			fg = next()
		case "--background", "-b":
			bg = next()
		case "--border-foreground":
			bfg = next()
		case "--border":
			border = next()
		case "--align":
			align = next()
		case "--width":
			width, _ = strconv.Atoi(next())
		case "--height":
			height, _ = strconv.Atoi(next())
		case "--margin":
			margin = next()
		case "--padding":
			padding = next()
		case "--bold":
			bold = true
		case "--italic":
			italic = true
		case "--underline":
			underline = true
		case "--strikethrough":
			strike = true
		case "--dim":
			dim = true
		case "--reverse":
			reverse = true
		case "--":
			text = append(text, args[i+1:]...)
			i = len(args)
		default:
			if strings.HasPrefix(a, "-") && len(a) > 1 {
				fmt.Fprintf(os.Stderr, "nui style: opcion no soportada: %s\n", a)
				continue
			}
			text = append(text, a)
		}
	}

	st := lipgloss.NewStyle()
	if fg != "" {
		st = st.Foreground(parseColor(fg))
	}
	if bg != "" {
		st = st.Background(parseColor(bg))
	}
	if margin != "" {
		st = st.Margin(parseInts(margin)...)
	}
	if padding != "" {
		st = st.Padding(parseInts(padding)...)
	}
	if border != "" && border != "none" {
		st = st.Border(borderByName(border))
		if bfg != "" {
			st = st.BorderForeground(parseColor(bfg))
		} else if fg != "" {
			st = st.BorderForeground(parseColor(fg))
		}
	}
	if width > 0 {
		st = st.Width(width)
	}
	if height > 0 {
		st = st.Height(height)
	}
	if align != "" {
		st = st.Align(alignByName(align))
	}
	if bold {
		st = st.Bold(true)
	}
	if italic {
		st = st.Italic(true)
	}
	if underline {
		st = st.Underline(true)
	}
	if strike {
		st = st.Strikethrough(true)
	}
	if dim {
		st = st.Faint(true)
	}
	if reverse {
		st = st.Reverse(true)
	}
	fmt.Println(st.Render(strings.Join(text, "\n")))
	return nil
}

// cmdLog: lineas de estado tipo gum log.
func cmdLog(args []string) error {
	level := "info"
	var rest []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--level" && i+1 < len(args) {
			level = args[i+1]
			i++
			continue
		}
		if strings.HasPrefix(a, "--level=") {
			level = strings.TrimPrefix(a, "--level=")
			continue
		}
		rest = append(rest, a)
	}
	msg := strings.Join(rest, " ")
	var tag string
	var st lipgloss.Style
	switch level {
	case "warn", "warning":
		tag, st = "WARN", lipgloss.NewStyle().Bold(true).Foreground(colYellow)
	case "error", "err":
		tag, st = "ERROR", lipgloss.NewStyle().Bold(true).Foreground(colRed)
	case "ok":
		tag, st = "OK", lipgloss.NewStyle().Bold(true).Foreground(colGreen)
	case "debug":
		tag, st = "DEBUG", lipgloss.NewStyle().Foreground(colDim)
	default:
		tag, st = "INFO", lipgloss.NewStyle().Bold(true).Foreground(colGreen)
	}
	fmt.Printf("%s %s\n", st.Render(fmt.Sprintf("%-5s", tag)), msg)
	return nil
}
