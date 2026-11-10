package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// tuiIO resuelve entrada/salida interactiva.
// - entrada: stdin si es TTY, si no /dev/tty
// - salida: stderr si es TTY (stdout se reserva para resultados), si no stdout
func tuiIO() (in *os.File, out *os.File, ok bool) {
	if isTTY(os.Stdin) {
		in = os.Stdin
	} else if f, err := os.OpenFile("/dev/tty", os.O_RDWR, 0); err == nil {
		in = f
	} else {
		return nil, nil, false
	}
	if isTTY(os.Stderr) {
		out = os.Stderr
	} else if isTTY(os.Stdout) {
		out = os.Stdout
	} else {
		return nil, nil, false
	}
	return in, out, true
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return 1
}

func presetSpinner(name string) spinner.Spinner {
	switch name {
	case "line":
		return spinner.Line
	case "moon":
		return spinner.Moon
	case "minidot":
		return spinner.MiniDot
	case "pulse":
		return spinner.Pulse
	case "points":
		return spinner.Points
	case "globe":
		return spinner.Globe
	case "meter":
		return spinner.Meter
	case "hamburger":
		return spinner.Hamburger
	case "jump":
		return spinner.Jump
	case "ellipsis":
		return spinner.Ellipsis
	case "monkey":
		return spinner.Monkey
	default:
		return spinner.Dot
	}
}

// ---------------------------------------------------------------- spin

type spinDoneMsg struct{ code int }

type spinModel struct {
	sp    spinner.Model
	title string
	cmd   *exec.Cmd
	done  bool
	code  int
}

func runAndWait(c *exec.Cmd) tea.Cmd {
	return func() tea.Msg {
		err := c.Run()
		return spinDoneMsg{code: exitCode(err)}
	}
}

func (m spinModel) Init() tea.Cmd {
	return tea.Batch(m.sp.Tick, runAndWait(m.cmd))
}

func (m spinModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case spinDoneMsg:
		m.done = true
		m.code = msg.code
		return m, tea.Quit
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.sp, cmd = m.sp.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m spinModel) View() string {
	if m.done {
		return ""
	}
	if m.title == "" {
		return m.sp.View()
	}
	return m.sp.View() + " " + m.title
}

// cmdSpin corre un comando con spinner. Sale con el codigo del comando.
func cmdSpin(args []string) {
	spinnerName := "dot"
	title := ""
	var cmdArgs []string

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
		case "--spinner":
			spinnerName = next()
		case "--title", "--titulo":
			title = next()
		case "--":
			cmdArgs = args[i+1:]
			i = len(args)
		default:
			fmt.Fprintf(os.Stderr, "nui spin: opcion no soportada: %s\n", a)
		}
	}
	if len(cmdArgs) == 0 {
		fmt.Fprintln(os.Stderr, "nui spin: falta el comando (uso: nui spin --titulo t -- cmd...)")
		os.Exit(2)
	}

	c := exec.Command(cmdArgs[0], cmdArgs[1:]...)
	in, out, ok := tuiIO()
	if !ok {
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		os.Exit(exitCode(c.Run()))
	}
	_ = in

	sp := spinner.New(spinner.WithSpinner(presetSpinner(spinnerName)))
	sp.Style = lipgloss.NewStyle().Foreground(colAccent)

	p := tea.NewProgram(spinModel{sp: sp, title: title, cmd: c},
		tea.WithInput(nil), tea.WithOutput(out))
	final, err := p.Run()
	fmt.Fprint(out, "\r\033[K") // borra la linea del spinner
	if err != nil {
		os.Exit(1)
	}
	if fm, ok := final.(spinModel); ok {
		os.Exit(fm.code)
	}
	os.Exit(0)
}

// ---------------------------------------------------------------- input

type inputModel struct {
	ti       textinput.Model
	canceled bool
}

func (m inputModel) Init() tea.Cmd { return nil }

func (m inputModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "esc", "ctrl+c":
			m.canceled = true
			return m, tea.Quit
		case "enter", "ctrl+j":
			return m, tea.Quit
		}
	}
	var cmd tea.Cmd
	m.ti, cmd = m.ti.Update(msg)
	return m, cmd
}

func (m inputModel) View() string { return m.ti.View() }

func cmdInput(args []string) {
	prompt, placeholder, value := "", "", ""
	password := false
	width := 40

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
		case "--prompt":
			prompt = next()
		case "--placeholder":
			placeholder = next()
		case "--value", "--default":
			value = next()
		case "--password":
			password = true
		case "--width":
			width, _ = strconv.Atoi(next())
		default:
			fmt.Fprintf(os.Stderr, "nui input: opcion no soportada: %s\n", a)
		}
	}

	in, out, ok := tuiIO()
	if !ok {
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		fmt.Print(strings.TrimRight(line, "\r\n"))
		return
	}

	ti := textinput.New()
	ti.Prompt = prompt
	ti.Placeholder = placeholder
	ti.Width = width
	if password {
		ti.EchoMode = textinput.EchoPassword
	}
	if value != "" {
		ti.SetValue(value)
	}
	ti.Focus() // fija el foco en el modelo local (Init recibe una copia)

	p := tea.NewProgram(inputModel{ti: ti},
		tea.WithInput(in), tea.WithOutput(out))
	final, err := p.Run()
	if err != nil {
		os.Exit(1)
	}
	fm, ok := final.(inputModel)
	if !ok || fm.canceled {
		os.Exit(1)
	}
	fmt.Print(fm.ti.Value())
}

// ---------------------------------------------------------------- confirm

type confirmModel struct {
	question string
	sel      int // 0 = si, 1 = no
	done     bool
	result   bool
}

func (m confirmModel) Init() tea.Cmd { return nil }

func (m confirmModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "left", "right", "tab", "shift+tab", "h", "l":
			m.sel = 1 - m.sel
		case "y", "Y":
			m.done, m.result = true, true
			return m, tea.Quit
		case "n", "N":
			m.done, m.result = true, false
			return m, tea.Quit
		case "enter":
			m.done, m.result = true, m.sel == 0
			return m, tea.Quit
		case "esc", "ctrl+c":
			m.done, m.result = true, false
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m confirmModel) View() string {
	btn := func(label string, selected bool) string {
		st := lipgloss.NewStyle().Padding(0, 1)
		if selected {
			st = st.Background(colAccent).Foreground(colWhite).Bold(true)
		} else {
			st = st.Foreground(colDim)
		}
		return st.Render(label)
	}
	return fmt.Sprintf("%s\n\n %s  %s",
		lipgloss.NewStyle().Bold(true).Render(m.question),
		btn("Sí", m.sel == 0),
		btn("No", m.sel == 1))
}

func cmdConfirm(args []string) {
	question := strings.Join(args, " ")
	if question == "" {
		question = "Continuar?"
	}

	in, out, ok := tuiIO()
	if !ok {
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		l := strings.ToLower(strings.TrimSpace(line))
		if l == "y" || l == "yes" || l == "s" || l == "si" || l == "sí" {
			os.Exit(0)
		}
		os.Exit(1)
	}

	p := tea.NewProgram(confirmModel{question: question},
		tea.WithInput(in), tea.WithOutput(out))
	final, err := p.Run()
	if err != nil {
		os.Exit(1)
	}
	fm, ok := final.(confirmModel)
	if !ok || !fm.result {
		os.Exit(1)
	}
	os.Exit(0)
}

// ---------------------------------------------------------------- choose

type chooseModel struct {
	header   string
	options  []string
	cursor   int
	sel      map[int]bool
	multi    bool
	height   int
	canceled bool
}

func (m chooseModel) Init() tea.Cmd { return nil }

func (m chooseModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.options)-1 {
				m.cursor++
			}
		case " ":
			if m.multi {
				if m.sel[m.cursor] {
					delete(m.sel, m.cursor)
				} else {
					m.sel[m.cursor] = true
				}
			}
		case "enter", "ctrl+j":
			if !m.multi {
				m.sel[m.cursor] = true
			}
			return m, tea.Quit
		case "esc", "ctrl+c":
			m.canceled = true
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m chooseModel) View() string {
	var b strings.Builder
	if m.header != "" {
		b.WriteString(lipgloss.NewStyle().Foreground(colDim).Render(m.header))
		b.WriteString("\n\n")
	}

	start, end := 0, len(m.options)
	if m.height > 0 && len(m.options) > m.height {
		start = m.cursor - m.height/2
		if start < 0 {
			start = 0
		}
		end = start + m.height
		if end > len(m.options) {
			end = len(m.options)
			start = end - m.height
		}
	}

	for i := start; i < end; i++ {
		prefix := "  "
		if i == m.cursor {
			prefix = lipgloss.NewStyle().Foreground(colAccent).Bold(true).Render("❯ ")
		}
		check := ""
		if m.multi {
			if m.sel[i] {
				check = lipgloss.NewStyle().Foreground(colGreen).Render("[x] ")
			} else {
				check = "[ ] "
			}
		}
		line := prefix + check + m.options[i]
		if i == m.cursor {
			line = lipgloss.NewStyle().Bold(true).Render(line)
		}
		b.WriteString(line)
		if i < end-1 {
			b.WriteString("\n")
		}
	}
	return b.String()
}

func cmdChoose(args []string) {
	header := ""
	multi := false
	height := 0
	var options []string

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
		case "--header":
			header = next()
		case "--no-limit":
			multi = true
		case "--height":
			height, _ = strconv.Atoi(next())
		case "--":
			options = append(options, args[i+1:]...)
			i = len(args)
		default:
			if strings.HasPrefix(a, "-") && len(a) > 1 {
				fmt.Fprintf(os.Stderr, "nui choose: opcion no soportada: %s\n", a)
				continue
			}
			options = append(options, a)
		}
	}
	if len(options) == 0 {
		sc := bufio.NewScanner(os.Stdin)
		for sc.Scan() {
			if t := strings.TrimSpace(sc.Text()); t != "" {
				options = append(options, t)
			}
		}
	}
	if len(options) == 0 {
		os.Exit(1)
	}

	in, out, ok := tuiIO()
	if !ok {
		os.Exit(1)
	}

	p := tea.NewProgram(chooseModel{
		header:  header,
		options: options,
		sel:     map[int]bool{},
		multi:   multi,
		height:  height,
	}, tea.WithInput(in), tea.WithOutput(out))
	final, err := p.Run()
	if err != nil {
		os.Exit(1)
	}
	fm, ok := final.(chooseModel)
	if !ok || fm.canceled {
		os.Exit(1)
	}
	var picked []string
	for i := range fm.options {
		if fm.sel[i] {
			picked = append(picked, fm.options[i])
		}
	}
	if len(picked) > 0 {
		fmt.Println(strings.Join(picked, "\n"))
	}
	os.Exit(0)
}

// ---------------------------------------------------------------- pager

func cmdPager(args []string) error {
	if _, err := exec.LookPath("less"); err == nil && isTTY(os.Stdout) {
		c := exec.Command("less", append([]string{"-R"}, args...)...)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err == nil {
			return nil
		}
	}
	if len(args) == 0 {
		_, err := io.Copy(os.Stdout, os.Stdin)
		return err
	}
	for _, f := range args {
		b, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		fmt.Print(string(b))
	}
	return nil
}
