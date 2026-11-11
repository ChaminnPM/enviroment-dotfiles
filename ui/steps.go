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
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/term"
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
	Title       string      `json:"title"`
	Cmd         string      `json:"cmd"`
	Optional    bool        `json:"optional"`
	Interactive bool        `json:"interactive"`
	Estimate    int         `json:"estimate"` // segundos estimados (progreso automático)
	Inputs      []planInput `json:"inputs"`   // formulario dentro del panel
}

// planInput es un campo del formulario que el panel pide antes de ejecutar
// el paso. Los valores se guardan en $NUI_STATE_DIR/result-<N>.env.
type planInput struct {
	Type    string   `json:"type"` // input | password | confirm | select | key
	Name    string   `json:"name"`
	Prompt  string   `json:"prompt"`
	Default string   `json:"default"`
	Options []string `json:"options"`
	Multi   bool     `json:"multi"`
	Path    string   `json:"path,omitempty"` // para type=key
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
		for _, in := range p.Steps[i].Inputs {
			switch in.Type {
			case "input", "password", "confirm":
				if strings.TrimSpace(in.Name) == "" {
					return plan{}, fmt.Errorf("paso %d: input sin nombre", i+1)
				}
			case "select":
				if strings.TrimSpace(in.Name) == "" || len(in.Options) == 0 {
					return plan{}, fmt.Errorf("paso %d: select inválido", i+1)
				}
			case "key":
				if strings.TrimSpace(in.Name) == "" || strings.TrimSpace(in.Path) == "" {
					return plan{}, fmt.Errorf("paso %d: key inválida", i+1)
				}
			default:
				return plan{}, fmt.Errorf("paso %d: tipo de input desconocido: %s", i+1, in.Type)
			}
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
	title    string
	state    stepState
	percent  float64
	realProg bool // el script emitio ##progress (no estimar con la curva)
	logs     []string
	note     string
	started  time.Time
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
	quitNowMsg   struct{}
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

	logDir   string
	stateDir string
	run      *runner

	spinner  spinner.Model
	progress progress.Model

	// formulario dentro del panel
	formActive bool
	formIdx    int
	formVals   map[string]string
	formCursor int
	formSel    map[int]bool
	input      textinput.Model
	confirmYes bool

	reportScroll int
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

	ti := textinput.New()
	ti.Prompt = ""
	ti.CharLimit = 512

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
		input:     ti,
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
		if m.formActive {
			return m.handleFormKey(msg)
		}
		if m.finished {
			return m.handleReportKey(msg)
		}
		return m.handleKey(msg)

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case repaintMsg:
		return m, nil

	case quitNowMsg:
		return m, tea.Quit

	case startStepMsg:
		return m.begin(msg.idx)

	case lineMsg:
		return m.applyLine(msg)

	case stepTickMsg:
		if msg.idx != m.current || m.steps[msg.idx].state != stRunning {
			return m, nil
		}
		m.advanceProgress(msg.idx)
		return m, tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
			return stepTickMsg{idx: msg.idx}
		})

	case stepDoneMsg:
		return m.finishStep(msg)
	}
	return m, nil
}

func (m *stepsModel) markCanceled() {
	if m.current >= 0 && m.current < len(m.steps) && m.steps[m.current].state == stRunning {
		m.steps[m.current].state = stFailed
		m.steps[m.current].note = "cancelado por el usuario"
	}
}

func (m stepsModel) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		if m.current >= 0 && m.steps[m.current].state == stRunning {
			m.run.kill()
		}
		m.markCanceled()
		m.canceled = true
		if !m.finished {
			m.finished = true
			m.elapsed = time.Since(m.startedAt)
		}
		return m, tea.Batch(tea.ClearScreen, tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg {
			return quitNowMsg{}
		}))

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

func (m stepsModel) handleReportKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "esc", "ctrl+c":
		return m, tea.Quit
	case "up", "k":
		if m.reportScroll > 0 {
			m.reportScroll--
		}
	case "down", "j":
		m.reportScroll++
	case "pgup", "home":
		m.reportScroll = 0
	case "pgdown", "end":
		m.reportScroll += 20
	}
	return m, nil
}

// ------------------------------------------------------------ formulario

func (m stepsModel) startForm(idx int) (tea.Model, tea.Cmd) {
	m.formActive = true
	m.formIdx = 0
	m.formVals = map[string]string{}
	m.formSel = map[int]bool{}
	for _, in := range m.plan.Steps[idx].Inputs {
		if in.Type == "confirm" {
			def := in.Default == "true" || in.Default == "y" || in.Default == "s"
			m.formVals[in.Name] = strconv.FormatBool(def)
		}
	}
	m.prepareField(m.plan.Steps[idx].Inputs[0])
	return m, nil
}

func (m *stepsModel) prepareField(in planInput) {
	m.input.SetValue("")
	m.input.Placeholder = in.Default
	m.input.EchoMode = textinput.EchoNormal
	if in.Type == "password" {
		m.input.EchoMode = textinput.EchoPassword
	}
	if in.Default != "" && (in.Type == "input" || in.Type == "password") {
		m.input.SetValue(in.Default)
	}
	if in.Type == "confirm" {
		m.confirmYes = in.Default == "true" || in.Default == "y" || in.Default == "s"
		m.formVals[in.Name] = strconv.FormatBool(m.confirmYes)
	}
	if in.Type == "select" {
		m.formCursor = 0
		m.formSel = map[int]bool{}
		if in.Default != "" {
			for i, opt := range in.Options {
				if opt == in.Default {
					m.formSel[i] = true
					m.formCursor = i
				}
			}
		}
	}
	m.input.Focus()
}

func (m stepsModel) handleFormKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	idx := m.current
	if idx < 0 || idx >= len(m.plan.Steps) || m.formIdx >= len(m.plan.Steps[idx].Inputs) {
		m.formActive = false
		return m, nil
	}
	in := m.plan.Steps[idx].Inputs[m.formIdx]

	switch msg.String() {
	case "ctrl+c":
		m.formActive = false
		m.markCanceled()
		m.canceled = true
		m.finished = true
		m.elapsed = time.Since(m.startedAt)
		return m, tea.Batch(tea.ClearScreen, tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg {
			return quitNowMsg{}
		}))
	case "esc":
		m.formActive = false
		if m.plan.Steps[idx].Optional {
			m.skipStep(idx, "omitido por el usuario")
			return m.nextAfter(idx)
		}
		m.markCanceled()
		m.canceled = true
		m.finished = true
		m.elapsed = time.Since(m.startedAt)
		return m, tea.Batch(tea.ClearScreen, tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg {
			return quitNowMsg{}
		}))
	}

	switch in.Type {
	case "input", "password":
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		if msg.String() == "enter" {
			m.formVals[in.Name] = m.input.Value()
			return m.advanceForm(idx)
		}
		return m, cmd

	case "confirm":
		switch msg.String() {
		case "left", "right", "h", "l", "tab", " ", "x":
			cur := m.formVals[in.Name] == "true"
			m.confirmYes = !cur
			m.formVals[in.Name] = strconv.FormatBool(m.confirmYes)
		case "y", "Y", "s", "S":
			m.confirmYes = true
			m.formVals[in.Name] = "true"
			return m.advanceForm(idx)
		case "n", "N":
			m.confirmYes = false
			m.formVals[in.Name] = "false"
			return m.advanceForm(idx)
		case "enter":
			m.formVals[in.Name] = strconv.FormatBool(m.confirmYes)
			return m.advanceForm(idx)
		}

	case "select":
		switch msg.String() {
		case "up", "k":
			if m.formCursor > 0 {
				m.formCursor--
			}
		case "down", "j":
			if m.formCursor < len(in.Options)-1 {
				m.formCursor++
			}
		case " ":
			if in.Multi {
				if m.formSel[m.formCursor] {
					delete(m.formSel, m.formCursor)
				} else {
					m.formSel[m.formCursor] = true
				}
			} else {
				m.formSel = map[int]bool{m.formCursor: true}
			}
		case "enter":
			var vals []string
			for i, opt := range in.Options {
				if m.formSel[i] {
					vals = append(vals, opt)
				}
			}
			m.formVals[in.Name] = strings.Join(vals, "\n")
			return m.advanceForm(idx)
		}

	case "key":
		if msg.String() == "enter" {
			return m.advanceForm(idx)
		}
	}
	return m, nil
}

func (m stepsModel) advanceForm(idx int) (tea.Model, tea.Cmd) {
	inputs := m.plan.Steps[idx].Inputs
	if m.formIdx+1 >= len(inputs) {
		return m.finishForm(idx)
	}
	m.formIdx++
	m.prepareField(inputs[m.formIdx])
	return m, nil
}

func (m stepsModel) finishForm(idx int) (tea.Model, tea.Cmd) {
	m.formActive = false
	m.saveResults(idx)
	ps := m.plan.Steps[idx]
	if ps.Interactive {
		c := exec.Command("bash", "-c", ps.Cmd)
		c.Env = m.stepEnv("TERM=xterm-256color")
		return m, tea.ExecProcess(c, func(err error) tea.Msg {
			return stepDoneMsg{idx: idx, err: err}
		})
	}
	m.execStep(idx)
	return m, tea.Batch(tea.ClearScreen, tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
		return stepTickMsg{idx: idx}
	}))
}

func (m *stepsModel) skipStep(idx int, note string) {
	m.steps[idx].state = stSkipped
	m.steps[idx].note = note
	m.steps[idx].percent = 1
}

func (m stepsModel) nextAfter(idx int) (tea.Model, tea.Cmd) {
	m.current = -1
	if idx+1 < len(m.steps) {
		return m, tea.Tick(250*time.Millisecond, func(time.Time) tea.Msg {
			return startStepMsg{idx: idx + 1}
		})
	}
	m.finished = true
	m.elapsed = time.Since(m.startedAt)
	return m, tea.ClearScreen
}

// saveResults escribe los valores del formulario en $NUI_STATE_DIR.
func (m stepsModel) saveResults(idx int) {
	if m.stateDir == "" {
		return
	}
	_ = os.MkdirAll(m.stateDir, 0o755)
	var b strings.Builder
	for _, in := range m.plan.Steps[idx].Inputs {
		b.WriteString(in.Name + "=" + shellQuote(m.formVals[in.Name]) + "\n")
	}
	_ = os.WriteFile(filepath.Join(m.stateDir, fmt.Sprintf("result-%02d.env", idx+1)),
		[]byte(b.String()), 0o600)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func (m stepsModel) stepEnv(extra ...string) []string {
	env := append(os.Environ(), "TERM=dumb", "NO_COLOR=1", "CLICOLOR=0")
	if m.stateDir != "" {
		env = append(env, "NUI_STATE_DIR="+m.stateDir,
			fmt.Sprintf("NUI_STEP_RESULT=%s", filepath.Join(m.stateDir, fmt.Sprintf("result-%02d.env", m.current+1))))
	}
	return append(env, extra...)
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
	if len(ps.Inputs) > 0 {
		return m.startForm(idx)
	}
	if ps.Interactive {
		c := exec.Command("bash", "-c", ps.Cmd)
		c.Env = m.stepEnv("TERM=xterm-256color")
		return m, tea.ExecProcess(c, func(err error) tea.Msg {
			return stepDoneMsg{idx: idx, err: err}
		})
	}

	m.execStep(idx)
	return m, tea.Batch(tea.ClearScreen, tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
		return stepTickMsg{idx: idx}
	}))
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
	c.Env = m.stepEnv()
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
			st.realProg = true
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
		return m, tea.ClearScreen
	}

	if msg.idx+1 < len(m.steps) {
		return m, tea.Tick(300*time.Millisecond, func(time.Time) tea.Msg {
			return startStepMsg{idx: msg.idx + 1}
		})
	}
	m.finished = true
	m.elapsed = time.Since(m.startedAt)
	return m, tea.ClearScreen
}

// advanceProgress estima el avance con el tiempo transcurrido y la estimación.
func (m *stepsModel) advanceProgress(idx int) {
	st := &m.steps[idx]
	if st.state != stRunning || st.realProg || st.percent >= 0.97 {
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
	// Margen defensivo: no escribir nunca en la ultima celda (esquina inferior
	// derecha). Terminales con auto-wrap inmediato hacen scroll y corrompen el
	// frame; con columna derecha y fila inferior vacias eso es imposible.
	w, h := m.width-1, m.height-1
	if m.showHelp {
		return normalizeView(m.viewHelp(), w, h)
	}

	bodyH := h - 2
	leftW := clampInt(int(float64(w)*0.40), 28, 40)
	rightW := w - leftW - 2

	var right string
	switch {
	case m.formActive:
		right = m.viewForm(rightW, bodyH)
	case m.finished:
		right = m.viewReport(rightW, bodyH)
	default:
		right = m.viewPanel(rightW, bodyH)
	}
	body := lipgloss.JoinHorizontal(lipgloss.Top,
		normalizeView(m.viewSteps(leftW, bodyH), leftW, bodyH),
		"  ",
		normalizeView(right, rightW, bodyH),
	)

	out := lipgloss.JoinVertical(lipgloss.Left,
		body,
		stRule.Render(strings.Repeat("─", w)),
		m.viewFooter(w),
	)
	// Normaliza alto/ancho para que el renderer nunca superponga frames.
	return normalizeView(out, w, h)
}

// normalizeView garantiza exactamente h lineas y ancho <= w por linea.
func normalizeView(s string, w, h int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > h {
		lines = lines[:h]
	}
	for i, l := range lines {
		lines[i] = ansi.Truncate(l, w, "")
	}
	for len(lines) < h {
		lines = append(lines, "")
	}
	return strings.Join(lines, "\n")
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

// ------------------------------------------------------------ formulario

func (m stepsModel) viewForm(w, h int) string {
	innerW := maxInt(0, w-4)
	innerH := maxInt(0, h-2)
	idx := m.current
	if idx < 0 || idx >= len(m.plan.Steps) {
		return ""
	}
	ps := m.plan.Steps[idx]
	if m.formIdx >= len(ps.Inputs) {
		return ""
	}

	lines := []string{
		stHeader.Render(truncate(ps.Title+" · formulario", innerW)),
		"",
	}
	for i, in := range ps.Inputs {
		active := i == m.formIdx
		prefix := "  "
		if active {
			prefix = stCursor.Render("> ")
		}
		prompt := in.Prompt
		if active {
			prompt = stTitleRun.Render(truncate(prompt, innerW-2))
		} else {
			prompt = stTitlePend.Render(truncate(prompt, innerW-2))
		}
		lines = append(lines, prefix+prompt)

		switch in.Type {
		case "input", "password":
			disp := m.formVals[in.Name]
			if active {
				disp = m.input.Value()
			}
			if in.Type == "password" && disp != "" {
				disp = strings.Repeat("•", len([]rune(disp)))
			}
			if disp == "" {
				disp = in.Default
			}
			style := stLogLine
			if active {
				style = stTitleRun
			}
			lines = append(lines, prefix+"  "+stBracket.Render("[")+
				style.Render(truncate(disp, maxInt(0, innerW-4)))+stBracket.Render("]"))
			if active {
				lines = append(lines, "")
			}

		case "confirm":
			yes, no := stPendMark.Render("[ ] sí"), stPendMark.Render("[ ] no")
			if m.formVals[in.Name] == "true" {
				yes = stDoneMark.Render("[x] sí")
			} else {
				no = stDoneMark.Render("[x] no")
			}
			lines = append(lines, prefix+"  "+yes+"  "+no)
			if active {
				lines = append(lines, "")
			}

		case "select":
			maxOpts := innerH - 10
			if maxOpts < 5 {
				maxOpts = 5
			}
			start, end := 0, len(in.Options)
			if len(in.Options) > maxOpts {
				start = 0
				if m.formCursor >= maxOpts {
					start = m.formCursor - maxOpts + 1
				}
				end = start + maxOpts
				if end > len(in.Options) {
					end = len(in.Options)
					start = maxInt(0, end-maxOpts)
				}
			}
			for oi := start; oi < end; oi++ {
				mark := stPendMark.Render("[ ]")
				if m.formSel[oi] {
					mark = stDoneMark.Render("[x]")
				}
				cur := "  "
				if active && oi == m.formCursor {
					cur = stCursor.Render("> ")
				}
				lines = append(lines, prefix+"  "+cur+mark+" "+
					stLogLine.Render(truncate(in.Options[oi], maxInt(0, innerW-8))))
			}
			if len(in.Options) > maxOpts {
				lines = append(lines, stFaint.Render(truncate(
					fmt.Sprintf("  mostrando %d-%d de %d · ↑/↓ para moverse", start+1, end, len(in.Options)), innerW)))
			}
			if active {
				lines = append(lines, "")
			}

		case "key":
			path := os.ExpandEnv(in.Path)
			if strings.HasPrefix(path, "~/") {
				if home, err := os.UserHomeDir(); err == nil {
					path = filepath.Join(home, path[2:])
				}
			}
			data, err := os.ReadFile(path)
			if err != nil {
				lines = append(lines, prefix+"  "+stFaint.Render(truncate("(sin generar: el paso de identidad no creo esta clave)", maxInt(0, innerW-4))))
			} else {
				text := strings.TrimRight(string(data), "\n")
				ww := maxInt(8, innerW-4)
				for _, kl := range strings.Split(text, "\n") {
					for _, piece := range wrapLine(kl, ww) {
						lines = append(lines, prefix+"  "+stLogLine.Render(piece))
					}
				}
			}
			if active {
				lines = append(lines, "", stFaint.Render(truncate("archivo: "+in.Path, innerW)),
					stFaint.Render(truncate("pulsa enter para continuar", innerW)))
			}
		}
	}

	hint := "[enter] continuar · [espacio] marcar · [esc] cancelar"
	if ps.Optional {
		hint = "[enter] continuar · [espacio] marcar · [esc] omitir"
	}
	lines = append(lines, stFaint.Render(truncate(hint, innerW)))

	maxLines := maxInt(1, innerH-2)
	if len(lines) > maxLines {
		lines = lines[:maxLines]
	}
	return stPanelBox.Width(w - 2).Height(h - 2).Render(strings.Join(lines, "\n"))
}

// ------------------------------------------------------------ reporte

func (m stepsModel) viewReport(w, h int) string {
	innerW := maxInt(0, w-4)
	innerH := maxInt(0, h-2)
	oks, warns, errs, infos := m.reportData()

	head := stHeaderOK.Render("Instalación completada")
	switch {
	case m.canceled:
		head = stHeaderWr.Render("Instalación cancelada por el usuario")
	case len(errs) > 0:
		head = stHeaderEr.Render("Instalación con errores")
	case len(warns) > 0:
		head = stHeaderWr.Render("Instalación con avisos")
	}

	lines := []string{head, ""}
	addSection := func(label string, color lipgloss.TerminalColor, items []string, symbol string) {
		if len(items) == 0 {
			return
		}
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(color).
			Render(fmt.Sprintf("%s (%d)", label, len(items))))
		for _, it := range items {
			lines = append(lines, "  "+lipgloss.NewStyle().Bold(true).Foreground(color).
				Render(symbol)+" "+stLogLine.Render(truncate(it, maxInt(0, innerW-4))))
		}
		lines = append(lines, "")
	}
	addSection("INSTALADO", colGreen, oks, "✓")
	addSection("AVISOS", colYellow, warns, "!")
	addSection("ERRORES", colRed, errs, "✗")
	for _, in := range infos {
		lines = append(lines, stFaint.Render(truncate(in, innerW)))
	}

	maxLines := maxInt(1, innerH-2)
	scroll := m.reportScroll
	if scroll < 0 {
		scroll = 0
	}
	if scroll > len(lines)-maxLines {
		scroll = maxInt(0, len(lines)-maxLines)
	}
	if len(lines) > maxLines {
		lines = lines[scroll:]
		if len(lines) > maxLines {
			lines = lines[:maxLines]
		}
	}
	return stPanelBox.Width(w - 2).Height(h - 2).Render(strings.Join(lines, "\n"))
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
		if i := m.firstState(stFailed); i >= 0 {
			return i
		}
		return len(m.steps) - 1
	}
	return m.cursor
}

func (m stepsModel) firstState(s stepState) int {
	for i, st := range m.steps {
		if st.state == s {
			return i
		}
	}
	return -1
}

func (m stepsModel) viewFooter(w int) string {
	if m.formActive {
		hint := "[enter] continuar · [esc] cancelar"
		if m.current >= 0 && m.plan.Steps[m.current].Optional {
			hint = "[enter] continuar · [esc] omitir"
		}
		return lipgloss.NewStyle().MaxWidth(w).Render(
			" " + stFootTxt.Render(truncate(hint, w-1)))
	}

	title := shorten(m.plan.Title)
	var keys [][2]string
	if m.finished {
		title = "Logs: " + m.logDir
		keys = [][2]string{{"↑/↓", "desplazar"}, {"q", "salir"}, {"?", "ayuda"}}
	} else {
		keys = [][2]string{{"↑/↓", "navegar"}, {"enter", "detalle"}, {"q", "cancelar"}, {"?", "ayuda"}}
	}

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, stFootKey.Render("["+k[0]+"]")+" "+stFootTxt.Render(k[1]))
	}
	line := stFootTxt.Render(title) + "  " + strings.Join(parts, stFootSep.Render(" • "))
	return lipgloss.NewStyle().MaxWidth(w).Render(" " + line)
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

	boxW := minInt(maxW+6, maxInt(24, m.width-4))
	box := stHelpBox.Width(boxW).Render(strings.Join([]string{
		stHelpTitle.Render("Atajos de teclado"),
		"",
		strings.Join(lines, "\n"),
		"",
		stFaint.Render("pulsa ? para volver"),
	}, "\n"))

	w, h := m.width-1, m.height-1
	placed := lipgloss.Place(w, h-2, lipgloss.Center, lipgloss.Center, box)
	return lipgloss.JoinVertical(lipgloss.Left,
		placed,
		stRule.Render(strings.Repeat("─", w)),
		m.viewFooter(w),
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

// reportData construye las secciones del reporte final.
func (m stepsModel) reportData() ([]string, []string, []string, []string) {
	oks, warns, errs, infos := []string{}, []string{}, []string{}, []string{}
	for _, st := range m.steps {
		title := st.title
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
			if st.note != "" {
				warns = append(warns, fmt.Sprintf("%s: %s", title, st.note))
			}
		}
	}
	if m.canceled {
		errs = append(errs, "Ejecución cancelada por el usuario")
	}
	infos = append(infos,
		fmt.Sprintf("Duración: %s", shortDur(m.elapsed)),
		"Logs: "+m.logDir)
	infos = append(infos, m.plan.Notes...)
	return oks, warns, errs, infos
}

func (m stepsModel) hasErrors() bool {
	_, _, errs, _ := m.reportData()
	return len(errs) > 0
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

	stateDir, err := os.MkdirTemp("", "nui-steps-state-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "nui steps:", err)
		return 1
	}
	defer os.RemoveAll(stateDir)

	if plain || !tty || w < 64 || h < 14 {
		return runPlanPlain(p, logDir, stateDir)
	}

	stepsProgram = nil
	m := newStepsModel(p, logDir)
	m.stateDir = stateDir
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
	if fm.hasErrors() {
		return 1
	}
	return 0
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
func runPlanPlain(p plan, logDir, stateDir string) int {
	oks, warns, errs := []string{}, []string{}, []string{}
	start := time.Now()

	clearScreen()
	fmt.Println(bannerBox(termWidth(), 0, []string{p.Title}))

	inputReader := bufio.NewReader(os.Stdin)
	for i, ps := range p.Steps {
		fmt.Printf("\n\033[1m== [%d/%d] %s ==\033[0m\n", i+1, len(p.Steps), ps.Title)
		promptInputs(stateDir, i, ps.Inputs, inputReader)

		c := exec.Command("bash", "-c", ps.Cmd)
		env := append(os.Environ(), "TERM=dumb")
		if stateDir != "" {
			env = append(env, "NUI_STATE_DIR="+stateDir,
				fmt.Sprintf("NUI_STEP_RESULT=%s", filepath.Join(stateDir, fmt.Sprintf("result-%02d.env", i+1))))
		}
		c.Env = env
		c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

		warned := false
		var err error
		if ps.Interactive {
			c.Stdin = os.Stdin
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
						warned = true
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
		if warned {
			warns = append(warns, ps.Title)
		} else {
			oks = append(oks, ps.Title)
		}
	}

	printReport(p.Title+" · REPORTE FINAL", oks, warns, errs,
		append([]string{fmt.Sprintf("Duración: %s", shortDur(time.Since(start))), "Logs: " + logDir}, p.Notes...))
	if len(errs) > 0 {
		return 1
	}
	return 0
}

// promptInputs pide los campos del paso por stdin y escribe result-<N>.env.
func promptInputs(stateDir string, idx int, inputs []planInput, rd *bufio.Reader) {
	if len(inputs) == 0 || stateDir == "" {
		return
	}
	_ = os.MkdirAll(stateDir, 0o755)
	var b strings.Builder
	for _, in := range inputs {
		val := in.Default
		switch in.Type {
		case "input", "password":
			fmt.Printf("\n%s", in.Prompt)
			if in.Default != "" {
				fmt.Printf(" [%s]", in.Default)
			}
			fmt.Print(" ")
			if in.Type == "password" && term.IsTerminal(int(os.Stdin.Fd())) {
				pw, err := term.ReadPassword(int(os.Stdin.Fd()))
				fmt.Println()
				if err == nil {
					val = string(pw)
				}
			} else {
				line, _ := rd.ReadString('\n')
				val = strings.TrimRight(line, "\r\n")
			}
			if val == "" {
				val = in.Default
			}
		case "confirm":
			fmt.Printf("\n%s [s/n] (%s): ", in.Prompt, defaultYesNo(in.Default))
			line, _ := rd.ReadString('\n')
			line = strings.ToLower(strings.TrimSpace(line))
			if line == "" {
				line = defaultYesNo(in.Default)
			}
			val = "false"
			if line == "s" || line == "si" || line == "sí" || line == "y" || line == "yes" || line == "true" {
				val = "true"
			}
		case "key":
			fmt.Printf("\n%s\n", in.Prompt)
			path := os.ExpandEnv(in.Path)
			if strings.HasPrefix(path, "~/") {
				if home, err := os.UserHomeDir(); err == nil {
					path = filepath.Join(home, path[2:])
				}
			}
			if data, err := os.ReadFile(path); err == nil {
				fmt.Print(string(data))
			} else {
				fmt.Printf("(sin generar: el paso de identidad no creo esta clave)\n")
			}
			fmt.Print("Pulsa enter para continuar... ")
			_, _ = rd.ReadString('\n')
		case "select":
			fmt.Printf("\n%s\n", in.Prompt)
			for oi, opt := range in.Options {
				fmt.Printf("  %2d) %s\n", oi+1, opt)
			}
			fmt.Print("Selección (números separados por espacio): ")
			line, _ := rd.ReadString('\n')
			var picked []string
			for _, f := range strings.Fields(line) {
				n, err := strconv.Atoi(f)
				if err != nil || n < 1 || n > len(in.Options) {
					continue
				}
				picked = append(picked, in.Options[n-1])
				if !in.Multi {
					break
				}
			}
			if len(picked) == 0 {
				picked = strings.Fields(in.Default)
			}
			val = strings.Join(picked, "\n")
		}
		b.WriteString(in.Name + "=" + shellQuote(val) + "\n")
	}
	_ = os.WriteFile(filepath.Join(stateDir, fmt.Sprintf("result-%02d.env", idx+1)),
		[]byte(b.String()), 0o600)
}

func defaultYesNo(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "true", "s", "si", "sí", "y", "yes":
		return "s"
	}
	return "n"
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

func wrapLine(s string, w int) []string {
	if w < 1 {
		return []string{s}
	}
	var out []string
	line := ""
	flush := func() {
		if line != "" {
			out = append(out, line)
			line = ""
		}
	}
	for _, word := range strings.Fields(s) {
		r := []rune(word)
		for len(r) > w {
			flush()
			out = append(out, string(r[:w]))
			r = r[w:]
		}
		word = string(r)
		if line == "" {
			line = word
			continue
		}
		if len([]rune(line))+1+len([]rune(word)) <= w {
			line += " " + word
		} else {
			flush()
			line = word
		}
	}
	flush()
	if len(out) == 0 {
		out = append(out, "")
	}
	return out
}

func truncate(s string, w int) string {
	if w <= 1 {
		return ""
	}
	return ansi.Truncate(s, w, "…")
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
