package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ---------------------------------------------------------------- plan

// planStep es una tarea del plan que ejecuta nui.
// Los comandos pueden emitir directivas por stdout:
//
//	##progress 45      fija el porcentaje del paso
//	##log texto        añade una línea limpia al panel
//	##title texto      cambia el título visible del paso
//	##warn texto       marca el paso como aviso y continúa
type planStep struct {
	Title       string `json:"title"`
	Cmd         string `json:"cmd"`
	Optional    bool   `json:"optional"`
	Interactive bool   `json:"interactive"`
	Estimate    int    `json:"estimate"` // segundos estimados (progreso automático)
}

type plan struct {
	Title string     `json:"title"`
	Notes []string   `json:"notes"`
	Steps []planStep `json:"steps"`
}

func loadPlan(path string) (plan, error) {
	var (
		raw []byte
		err error
	)
	if path == "" || path == "-" {
		raw, err = io.ReadAll(os.Stdin)
	} else {
		raw, err = os.ReadFile(path)
	}
	if err != nil {
		return plan{}, err
	}
	var p plan
	if err := json.Unmarshal(raw, &p); err != nil {
		return plan{}, fmt.Errorf("plan inválido: %w", err)
	}
	if len(p.Steps) == 0 {
		return plan{}, errors.New("el plan no tiene pasos")
	}
	for i := range p.Steps {
		if strings.TrimSpace(p.Steps[i].Cmd) == "" {
			return plan{}, fmt.Errorf("paso %d sin comando", i+1)
		}
		if p.Steps[i].Title == "" {
			p.Steps[i].Title = fmt.Sprintf("Paso %d", i+1)
		}
	}
	if p.Title == "" {
		p.Title = "INSTALACIÓN"
	}
	return p, nil
}

// ---------------------------------------------------------------- estado

type stepState int

const (
	stPending stepState = iota
	stRunning
	stDone
	stWarn
	stFailed
	stSkipped
)

type runStep struct {
	title   string
	state   stepState
	percent float64
	logs    []string
	note    string
	started time.Time
}

const (
	maxStepLogs  = 400
	maxPanelLogs = 500
	maxLineLen   = 400
)

// ---------------------------------------------------------------- mensajes

type (
	lineMsg struct {
		idx  int
		line string
	}
	stepDoneMsg struct {
		idx int
		err error
	}
	stepTickMsg  struct{ idx int }
	startStepMsg struct{ idx int }
	repaintMsg   struct{}
)

// ---------------------------------------------------------------- runner

// runner comparte el proceso hijo con el modelo para poder cancelarlo.
type runner struct {
	mu     sync.Mutex
	cmd    *exec.Cmd
	killed bool
}

func (r *runner) setCmd(c *exec.Cmd) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cmd = c
	if r.killed && c.Process != nil {
		killGroup(c)
	}
}

func (r *runner) clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cmd = nil
}

func (r *runner) kill() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.killed = true
	if r.cmd != nil && r.cmd.Process != nil {
		killGroup(r.cmd)
	}
}

func killGroup(c *exec.Cmd) {
	if c.Process == nil {
		return
	}
	if pgid, err := syscall.Getpgid(c.Process.Pid); err == nil && pgid > 0 {
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
	}
	_ = c.Process.Kill()
}

// ---------------------------------------------------------------- modelo

type stepsModel struct {
	plan     plan
	steps    []runStep
	cursor   int
	current  int
	pinned   int
	canceled bool
	finished bool
	showHelp bool

	width  int
	height int

	startedAt time.Time
	elapsed   time.Duration

	logDir string
	run    *runner

	spinner  spinner.Model
	progress progress.Model
}

func newStepsModel(p plan, logDir string) stepsModel {
	prog := progress.New(
		progress.WithoutPercentage(),
		progress.WithSolidFill("#7B7FE6"),
		progress.WithFillCharacters('█', '░'),
	)
	prog.EmptyColor = "#4B4F60"

	sp := spinner.New()
	sp.Spinner = spinner.MiniDot
	sp.Style = lipgloss.NewStyle().Foreground(colAccent)

	steps := make([]runStep, len(p.Steps))
	for i, s := range p.Steps {
		steps[i] = runStep{title: s.Title}
	}

	return stepsModel{
		plan:      p,
		steps:     steps,
		current:   0,
		pinned:    -1,
		logDir:    logDir,
		run:       &runner{},
		startedAt: time.Now(),
		spinner:   sp,
		progress:  prog,
	}
}

func (m stepsModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.startStep(0))
}

func (m stepsModel) startStep(idx int) tea.Cmd {
	return func() tea.Msg { return startStepMsg{idx: idx} }
}

func (m stepsModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case repaintMsg:
		return m, nil

	case startStepMsg:
		return m.begin(msg.idx)

	case lineMsg:
		return m.applyLine(msg)

	case stepTickMsg:
		if msg.idx != m.current || m.steps[msg.idx].state != stRunning {
			return m, nil
		}
		m.advanceProgress(msg.idx)
		return m, tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg {
			return stepTickMsg{idx: msg.idx}
		})

	case stepDoneMsg:
		return m.finishStep(msg)
	}
	return m, nil
}

func (m stepsModel) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		if m.current >= 0 && m.steps[m.current].state == stRunning {
			m.run.kill()
		}
		if !m.finished {
			m.canceled = true
			m.elapsed = time.Since(m.startedAt)
		}
		return m, tea.Quit

	case "?":
		m.showHelp = !m.showHelp

	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}

	case "down", "j":
		if m.cursor < len(m.steps)-1 {
			m.cursor++
		}

	case "enter":
		if m.pinned == m.cursor {
			m.pinned = -1
		} else {
			m.pinned = m.cursor
		}
	}
	return m, nil
}

// begin arranca el paso idx: interactivo (cede la terminal) o con panel en vivo.
func (m stepsModel) begin(idx int) (tea.Model, tea.Cmd) {
	if idx < 0 || idx >= len(m.plan.Steps) {
		return m, nil
	}
	st := &m.steps[idx]
	st.state = stRunning
	st.percent = 0
	st.logs = nil
	st.note = ""
	st.started = time.Now()
	m.current = idx
	m.cursor = idx

	ps := m.plan.Steps[idx]
	if ps.Interactive {
		c := exec.Command("bash", "-c", ps.Cmd)
		c.Env = append(os.Environ(), "TERM=xterm-256color")
		return m, tea.ExecProcess(c, func(err error) tea.Msg {
			return stepDoneMsg{idx: idx, err: err}
		})
	}

	m.execStep(idx)
	return m, tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg {
		return stepTickMsg{idx: idx}
	})
}

// execStep lanza el comando y transmite su salida al panel línea a línea.
func (m *stepsModel) execStep(idx int) {
	ps := m.plan.Steps[idx]
	logPath := m.logPath(idx)
	logFile, logErr := os.Create(logPath)
	if logErr != nil {
		logFile = nil
	}

	c := exec.Command("bash", "-c", ps.Cmd)
	c.Env = append(os.Environ(), "TERM=dumb", "NO_COLOR=1", "CLICOLOR=0")
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	pr, pw := io.Pipe()
	c.Stdout = pw
	c.Stderr = pw

	go func() {
		defer func() {
			if logFile != nil {
				logFile.Close()
			}
		}()
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := sc.Text()
			if logFile != nil {
				fmt.Fprintln(logFile, line)
			}
			if stepsProgram != nil {
				stepsProgram.Send(lineMsg{idx: idx, line: line})
			}
		}
	}()

	if err := c.Start(); err != nil {
		pw.Close()
		m.run.clear()
		go func() {
			if stepsProgram != nil {
				stepsProgram.Send(stepDoneMsg{idx: idx, err: err})
			}
		}()
		return
	}
	m.run.setCmd(c)

	go func() {
		err := c.Wait()
		pw.Close() // el scanner termina y entrega lo pendiente
		time.Sleep(30 * time.Millisecond)
		m.run.clear()
		if stepsProgram != nil {
			stepsProgram.Send(stepDoneMsg{idx: idx, err: err})
		}
	}()
}

func (m stepsModel) applyLine(msg lineMsg) (tea.Model, tea.Cmd) {
	if msg.idx < 0 || msg.idx >= len(m.steps) {
		return m, nil
	}
	st := &m.steps[msg.idx]

	kind, rest := directive(msg.line)
	switch kind {
	case "progress":
		if v, err := strconv.ParseFloat(strings.TrimSpace(rest), 64); err == nil {
			st.percent = clampPct(v / 100)
		}
		return m, nil
	case "log":
		st.logs = appendLog(st.logs, rest)
		return m, nil
	case "title":
		if t := strings.TrimSpace(rest); t != "" {
			st.title = t
			m.plan.Steps[msg.idx].Title = t
		}
		return m, nil
	case "warn":
		st.state = stWarn
		st.note = strings.TrimSpace(rest)
		st.logs = appendLog(st.logs, st.note)
		return m, nil
	}

	clean := cleanLine(msg.line)
	if clean == "" {
		return m, nil
	}
	st.logs = appendLog(st.logs, clean)
	return m, nil
}

func (m stepsModel) finishStep(msg stepDoneMsg) (tea.Model, tea.Cmd) {
	if msg.idx >= len(m.steps) {
		return m, nil
	}
	st := &m.steps[msg.idx]
	st.percent = 1

	switch {
	case msg.err != nil:
		st.state = stFailed
		if st.note == "" {
			st.note = errText(msg.err)
		}
		st.logs = appendLog(st.logs, "✗ "+errText(msg.err))
	case st.state != stWarn:
		st.state = stDone
	}

	// Aviso opcional: el paso no es fatal.
	if msg.err != nil && m.plan.Steps[msg.idx].Optional {
		st.state = stWarn
		if st.note == "" {
			st.note = "falló (opcional)"
		}
	}
	m.current = -1

	if msg.err != nil && !m.plan.Steps[msg.idx].Optional {
		for i := msg.idx + 1; i < len(m.steps); i++ {
			m.steps[i].state = stSkipped
		}
		m.finished = true
		m.elapsed = time.Since(m.startedAt)
		return m, nil
	}

	if msg.idx+1 < len(m.steps) {
		return m, tea.Tick(300*time.Millisecond, func(time.Time) tea.Msg {
			return startStepMsg{idx: msg.idx + 1}
		})
	}
	m.finished = true
	m.elapsed = time.Since(m.startedAt)
	return m, nil
}

// advanceProgress estima el avance con el tiempo transcurrido y la estimación.
func (m *stepsModel) advanceProgress(idx int) {
	st := &m.steps[idx]
	if st.state != stRunning || st.percent >= 0.97 {
		return
	}
	estimate := float64(m.plan.Steps[idx].Estimate)
	if estimate <= 0 {
		estimate = 12
	}
	tau := estimate / 2.5
	if tau < 1.5 {
		tau = 1.5
	}
	elapsed := time.Since(st.started).Seconds()
	target := 0.95 * (1 - 1/(1+elapsed/tau))
	if target > st.percent {
		st.percent = target
	}
}

func (m stepsModel) logPath(idx int) string {
	slug := slugify(m.plan.Steps[idx].Title)
	if slug == "" {
		slug = "paso"
	}
	return filepath.Join(m.logDir, fmt.Sprintf("steps-%s-%02d-%s.log",
		time.Now().Format("20060102-150405"), idx+1, slug))
}

// ---------------------------------------------------------------- vista

var (
	stHeader   = lipgloss.NewStyle().Foreground(colAccent).Bold(true)
	stHeaderOK = lipgloss.NewStyle().Foreground(colGreen).Bold(true)
	stHeaderWr = lipgloss.NewStyle().Foreground(colYellow).Bold(true)
	stHeaderEr = lipgloss.NewStyle().Foreground(colRed).Bold(true)
	stHeaderDm = lipgloss.NewStyle().Foreground(colDim).Bold(true)

	stRunMark  = lipgloss.NewStyle().Foreground(colAccent)
	stDoneMark = lipgloss.NewStyle().Foreground(colGreen)
	stWarnMark = lipgloss.NewStyle().Foreground(colYellow)
	stErrMark  = lipgloss.NewStyle().Foreground(colRed)
	stPendMark = lipgloss.NewStyle().Foreground(colDim)

	stCursor    = lipgloss.NewStyle().Foreground(colAccent).Bold(true)
	stTitleDone = lipgloss.NewStyle().Foreground(colGreen)
	stTitleRun  = lipgloss.NewStyle().Foreground(colWhite).Bold(true)
	stTitlePend = lipgloss.NewStyle().Foreground(colDim)
	stTitleWarn = lipgloss.NewStyle().Foreground(colYellow)
	stTitleErr  = lipgloss.NewStyle().Foreground(colRed)

	stPanelBox = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).
			BorderForeground(colDim).Padding(0, 1)
	stBracket = lipgloss.NewStyle().Foreground(colDim)
	stPercent = lipgloss.NewStyle().Foreground(colDim)
	stCounter = lipgloss.NewStyle().Foreground(colDim)
	stArrow   = lipgloss.NewStyle().Foreground(colDim)
	stLogLine = lipgloss.NewStyle().Foreground(colWhite)
	stFaint   = lipgloss.NewStyle().Foreground(colDim).Italic(true)

	stRule    = lipgloss.NewStyle().Foreground(colDim)
	stFootKey = lipgloss.NewStyle().Foreground(colWhite)
	stFootTxt = lipgloss.NewStyle().Foreground(colDim)
	stFootSep = lipgloss.NewStyle().Foreground(colDim)

	stHelpBox = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).
			BorderForeground(colDim).Padding(1, 3)
	stHelpTitle = lipgloss.NewStyle().Foreground(colAccent).Bold(true)
	stHelpKey   = lipgloss.NewStyle().Foreground(colWhite).Bold(true)
)

func (m stepsModel) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}
	if m.showHelp {
		return m.viewHelp()
	}

	bodyH := m.height - 2
	leftW := clampInt(int(float64(m.width)*0.40), 28, 40)
	rightW := m.width - leftW - 2

	body := lipgloss.JoinHorizontal(lipgloss.Top,
		m.viewSteps(leftW, bodyH),
		"  ",
		m.viewPanel(rightW, bodyH),
	)

	return lipgloss.JoinVertical(lipgloss.Left,
		body,
		stRule.Render(strings.Repeat("─", m.width)),
		m.viewFooter(),
	)
}

func (m stepsModel) viewSteps(w, h int) string {
	lines := make([]string, 0, h)
	lines = append(lines, stHeader.Render(truncate(shorten(m.plan.Title), w)))
	lines = append(lines, "")

	rows := h - 2
	if rows < 1 {
		rows = 1
	}
	start := 0
	if len(m.steps) > rows {
		focus := m.cursor
		if m.current >= 0 {
			focus = m.current
		}
		start = focus - rows/2
		if start < 0 {
			start = 0
		}
		if start+rows > len(m.steps) {
			start = len(m.steps) - rows
		}
	}
	end := start + rows
	if end > len(m.steps) {
		end = len(m.steps)
	}

	for i := start; i < end; i++ {
		s := m.steps[i]
		cursor := " "
		if i == m.cursor && !m.finished {
			cursor = stCursor.Render(">")
		}

		var marker string
		var titleStyle lipgloss.Style
		switch s.state {
		case stDone:
			marker, titleStyle = stDoneMark.Render("[✓]"), stTitleDone
		case stRunning:
			marker, titleStyle = stRunMark.Render("["+m.spinner.View()+"]"), stTitleRun
		case stWarn:
			marker, titleStyle = stWarnMark.Render("[!]"), stTitleWarn
		case stFailed:
			marker, titleStyle = stErrMark.Render("[✗]"), stTitleErr
		case stSkipped:
			marker, titleStyle = stPendMark.Render("[-]"), stTitlePend
		default:
			marker, titleStyle = stPendMark.Render("[ ]"), stTitlePend
		}

		label := truncate(fmt.Sprintf("%d. %s", i+1, s.title), w-6)
		lines = append(lines, cursor+" "+marker+" "+titleStyle.Render(label))
	}

	if len(lines) > h {
		lines = lines[:h]
	}
	return lipgloss.NewStyle().Width(w).Height(h).Render(strings.Join(lines, "\n"))
}

func (m stepsModel) viewPanel(w, h int) string {
	innerW := maxInt(0, w-4)
	innerH := maxInt(0, h-2)

	idx := m.viewIndex()
	var cur runStep
	if idx >= 0 && idx < len(m.steps) {
		cur = m.steps[idx]
	}

	title, titleStyle := m.panelTitle(cur)
	prefix := "  "
	if cur.state == stRunning {
		prefix = m.spinner.View() + " "
	}
	header := prefix + titleStyle.Render(truncate(title, innerW-2))

	barW := innerW - 7
	if barW < 8 {
		barW = 8
	}
	prog := m.progress
	prog.Width = barW
	pct := clampPct(cur.percent)
	bar := lipgloss.JoinHorizontal(lipgloss.Center,
		stBracket.Render("["),
		prog.ViewAs(pct),
		stBracket.Render("]"),
		" ",
		stPercent.Render(fmt.Sprintf("%3.0f%%", pct*100)),
	)

	counterText := fmt.Sprintf("(paso %d de %d)", maxInt(idx+1, 1), len(m.steps))
	if hint := " · enter para volver"; m.pinned >= 0 && len(counterText)+len(hint) <= innerW {
		counterText += hint
	}
	counter := stCounter.Width(innerW).Align(lipgloss.Right).Render(counterText)

	divider := stRule.Render(strings.Repeat("─", innerW))

	rows := innerH - 4
	if rows < 1 {
		rows = 1
	}
	logs := make([]string, 0, rows)
	for _, line := range tailLines(cur.logs, rows) {
		logs = append(logs, stArrow.Render("-> ")+stLogLine.Render(truncate(line, innerW-3)))
	}
	for len(logs) < rows {
		if len(logs) == 0 && len(cur.logs) == 0 {
			ph := "(esperando salida...)"
			switch cur.state {
			case stPending, stSkipped:
				ph = "(paso pendiente)"
			case stDone:
				ph = "(sin salida)"
			}
			logs = append(logs, stFaint.Render(ph))
			continue
		}
		logs = append(logs, "")
	}
	if len(logs) > rows {
		logs = logs[len(logs)-rows:]
	}

	content := strings.Join(append([]string{header, bar, counter, divider}, logs...), "\n")
	return stPanelBox.Width(w - 2).Height(h - 2).Render(content)
}

func (m stepsModel) panelTitle(cur runStep) (string, lipgloss.Style) {
	switch {
	case m.canceled:
		return "Cancelado por el usuario", stHeaderWr
	case m.finished:
		switch {
		case m.countState(stFailed) > 0:
			return "Instalación con errores", stHeaderEr
		case m.countState(stWarn) > 0:
			return "Instalación con avisos", stHeaderWr
		default:
			return fmt.Sprintf("Instalación completada en %s", shortDur(m.elapsed)), stHeaderOK
		}
	case cur.state == stRunning:
		return cur.title, stHeader
	}
	return m.plan.Title, stHeaderDm
}

func (m stepsModel) viewIndex() int {
	if m.pinned >= 0 {
		return m.pinned
	}
	if m.current >= 0 {
		return m.current
	}
	if m.finished {
		return len(m.steps) - 1
	}
	return m.cursor
}

func (m stepsModel) viewFooter() string {
	title := shorten(m.plan.Title)
	if m.finished || m.canceled {
		title = "Logs: " + m.logDir
	}
	keys := [][2]string{{"↑/↓", "navegar"}, {"enter", "detalle"}}
	if m.finished {
		keys = append(keys, [2]string{"q", "salir"})
	} else {
		keys = append(keys, [2]string{"q", "cancelar"})
	}
	keys = append(keys, [2]string{"?", "ayuda"})

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, stFootKey.Render("["+k[0]+"]")+" "+stFootTxt.Render(k[1]))
	}
	line := stFootTxt.Render(title) + "  " + strings.Join(parts, stFootSep.Render(" • "))
	return lipgloss.NewStyle().MaxWidth(m.width).Render(" " + line)
}

func (m stepsModel) viewHelp() string {
	rows := [][2]string{
		{"↑/↓ j/k", "navegar por la lista de pasos"},
		{"enter", "fijar / soltar el detalle de un paso"},
		{"q esc", "cancelar la ejecución y salir"},
		{"?", "cerrar esta ayuda"},
	}

	keyCol := lipgloss.NewStyle().Foreground(colWhite).Bold(true).Width(9)
	lines := make([]string, 0, len(rows))
	maxW := 0
	for _, r := range rows {
		line := keyCol.Render(r[0]) + stFootTxt.Render(r[1])
		if w := lipgloss.Width(line); w > maxW {
			maxW = w
		}
		lines = append(lines, line)
	}

	boxW := minInt(maxW+6, maxInt(24, m.width-2))
	box := stHelpBox.Width(boxW).Render(strings.Join([]string{
		stHelpTitle.Render("Atajos de teclado"),
		"",
		strings.Join(lines, "\n"),
		"",
		stFaint.Render("pulsa ? para volver"),
	}, "\n"))

	placed := lipgloss.Place(m.width, m.height-2, lipgloss.Center, lipgloss.Center, box)
	return lipgloss.JoinVertical(lipgloss.Left,
		placed,
		stRule.Render(strings.Repeat("─", m.width)),
		m.viewFooter(),
	)
}

func (m stepsModel) countState(s stepState) int {
	n := 0
	for _, st := range m.steps {
		if st.state == s {
			n++
		}
	}
	return n
}

// ---------------------------------------------------------------- informe

// report imprime el reporte final y devuelve el código de salida.
func (m stepsModel) report() int {
	oks, warns, errs, infos := []string{}, []string{}, []string{}, []string{}
	for i, st := range m.steps {
		title := fmt.Sprintf("%s", st.title)
		switch st.state {
		case stDone:
			oks = append(oks, title)
		case stWarn:
			if st.note != "" {
				warns = append(warns, fmt.Sprintf("%s: %s", title, st.note))
			} else {
				warns = append(warns, title)
			}
		case stFailed:
			note := st.note
			if note == "" {
				note = "falló"
			}
			errs = append(errs, fmt.Sprintf("%s: %s", title, note))
		case stSkipped:
			_ = i
		}
	}
	if m.canceled {
		errs = append(errs, "Ejecución cancelada por el usuario")
	}
	infos = append(infos,
		fmt.Sprintf("Duración: %s", shortDur(m.elapsed)),
		"Logs: "+m.logDir)
	infos = append(infos, m.plan.Notes...)

	failed := printReport(m.plan.Title+" · REPORTE FINAL", oks, warns, errs, infos)
	if failed {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------- ejecución

func cmdSteps(args []string) int {
	if len(args) == 0 || args[0] != "run" {
		fmt.Fprintln(os.Stderr, `nui steps: uso: nui steps run --plan <archivo|-> [--log-dir DIR] [--plain] [--title T]`)
		return 2
	}
	args = args[1:]

	planPath := "-"
	logDir := os.Getenv("LOG_DIR")
	plain := false
	title := ""

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
		case "--plan", "-p":
			planPath = next()
		case "--log-dir":
			logDir = next()
		case "--plain":
			plain = true
		case "--title":
			title = next()
		default:
			fmt.Fprintf(os.Stderr, "nui steps: opción no soportada: %s\n", a)
			return 2
		}
	}
	if logDir == "" {
		logDir = defaultLogDir()
	}
	_ = os.MkdirAll(logDir, 0o755)

	p, err := loadPlan(planPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "nui steps:", err)
		return 2
	}
	if title != "" {
		p.Title = title
	}

	in, out, tty := tuiIO()
	w, h := termSize(out)
	if plain || !tty || w < 64 || h < 14 {
		return runPlanPlain(p, logDir)
	}

	stepsProgram = nil
	m := newStepsModel(p, logDir)
	prog := tea.NewProgram(m,
		tea.WithInput(in),
		tea.WithOutput(out),
		tea.WithAltScreen(),
	)
	stepsProgram = prog

	final, err := prog.Run()
	stepsProgram = nil
	if err != nil {
		fmt.Fprintln(os.Stderr, "nui steps:", err)
		return 1
	}
	fm, ok := final.(stepsModel)
	if !ok {
		return 1
	}
	return fm.report()
}

// stepsProgram permite que los lectores envíen líneas al event loop.
var stepsProgram *tea.Program

func defaultLogDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".local/state/enviroment-dotfiles/logs")
}

// runPlanPlain ejecuta el plan sin TUI (verbose, CI o terminal pequeña).
func runPlanPlain(p plan, logDir string) int {
	oks, warns, errs := []string{}, []string{}, []string{}
	start := time.Now()

	clearScreen()
	fmt.Println(bannerBox(termWidth(), 0, []string{p.Title}))

	for i, ps := range p.Steps {
		fmt.Printf("\n\033[1m== [%d/%d] %s ==\033[0m\n", i+1, len(p.Steps), ps.Title)

		c := exec.Command("bash", "-c", ps.Cmd)
		c.Env = append(os.Environ(), "TERM=dumb")
		c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		c.Stdin = os.Stdin

		var err error
		if ps.Interactive {
			c.Stdout, c.Stderr = os.Stdout, os.Stderr
			err = c.Run()
		} else {
			pr, pw := io.Pipe()
			c.Stdout, c.Stderr = pw, pw
			logFile, _ := os.Create(filepath.Join(logDir,
				fmt.Sprintf("steps-%s-%02d-%s.log", start.Format("20060102-150405"), i+1, slugify(ps.Title))))
			done := make(chan struct{})
			go func() {
				defer close(done)
				sc := bufio.NewScanner(pr)
				sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
				for sc.Scan() {
					line := sc.Text()
					if logFile != nil {
						fmt.Fprintln(logFile, line)
					}
					kind, rest := directive(line)
					switch kind {
					case "log":
						fmt.Println(rest)
					case "warn":
						fmt.Println("[WARN] " + rest)
					case "title", "progress":
					default:
						if l := cleanLine(line); l != "" {
							fmt.Println(l)
						}
					}
				}
			}()
			if err = c.Start(); err == nil {
				err = c.Wait()
			}
			pw.Close()
			<-done
			if logFile != nil {
				logFile.Close()
			}
		}

		if err != nil {
			if ps.Optional {
				warns = append(warns, ps.Title+": falló (opcional)")
				fmt.Println("[WARN] falló (opcional)")
				continue
			}
			errs = append(errs, ps.Title+": "+errText(err))
			fmt.Println("[ERROR] " + errText(err))
			break
		}
		oks = append(oks, ps.Title)
	}

	printReport(p.Title+" · REPORTE FINAL", oks, warns, errs,
		append([]string{fmt.Sprintf("Duración: %s", shortDur(time.Since(start))), "Logs: " + logDir}, p.Notes...))
	if len(errs) > 0 {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------- utilidades

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)`)

func directive(line string) (kind, rest string) {
	if !strings.HasPrefix(line, "##") {
		return "", ""
	}
	body := strings.TrimPrefix(line, "##")
	if i := strings.IndexByte(body, ' '); i >= 0 {
		return body[:i], body[i+1:]
	}
	return body, ""
}

func cleanLine(line string) string {
	// las barras de progreso con \r dejan la última versión en pantalla
	if i := strings.LastIndexByte(line, '\r'); i >= 0 {
		line = line[i+1:]
	}
	line = ansiRe.ReplaceAllString(line, "")
	line = strings.TrimRight(line, " \t")
	if len(line) > maxLineLen {
		line = line[:maxLineLen]
	}
	return line
}

func appendLog(logs []string, line string) []string {
	line = strings.TrimSpace(line)
	if line == "" {
		return logs
	}
	logs = append(logs, line)
	if len(logs) > maxStepLogs {
		logs = logs[len(logs)-maxStepLogs:]
	}
	return logs
}

func errText(err error) string {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ee.ExitCode() > 0 {
			return fmt.Sprintf("exit %d", ee.ExitCode())
		}
		return "interrumpido"
	}
	return err.Error()
}

func shorten(s string) string { return s }

func slugify(s string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			prevDash = false
		case r >= 'á' && r <= 'ú', r == 'ñ', r == 'ü':
			b.WriteRune(r)
			prevDash = false
		default:
			if !prevDash {
				b.WriteByte('-')
				prevDash = true
			}
		}
	}
	return strings.Trim(b.String(), "-")
}

func shortDur(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%.1fs", d.Seconds())
	}
	return fmt.Sprintf("%dm %02ds", int(d.Minutes()), int(d.Seconds())%60)
}

func clampPct(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func truncate(s string, w int) string {
	if w <= 1 {
		return ""
	}
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	return string(r[:w-1]) + "…"
}

func tailLines(s []string, n int) []string {
	if n <= 0 || len(s) == 0 {
		return nil
	}
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

func termSize(f *os.File) (int, int) {
	if f != nil && isTTY(f) {
		if w, h, err := termGetSize(int(f.Fd())); err == nil && w > 0 && h > 0 {
			return w, h
		}
	}
	return termWidth(), 24
}
