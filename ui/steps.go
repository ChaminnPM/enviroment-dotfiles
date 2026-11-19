package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	Type    string           `json:"type"` // input | password | confirm | select | key
	Name    string           `json:"name"`
	Prompt  string           `json:"prompt"`
	Default string           `json:"default"`
	Options []string         `json:"options"`
	Multi   bool             `json:"multi"`
	Path    string           `json:"path,omitempty"`    // para type=key
	ShowIf  []inputCondition `json:"show_if,omitempty"` // todas las condiciones deben cumplirse
}

// inputCondition controla la visibilidad de un campo según el valor de otro
// campo ya respondido en el mismo formulario.
type inputCondition struct {
	Field string `json:"field"`
	Op    string `json:"op"`
	Value string `json:"value,omitempty"`
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
		for j, in := range p.Steps[i].Inputs {
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
			for k := range in.ShowIf {
				c := &in.ShowIf[k]
				c.Field = strings.TrimSpace(c.Field)
				c.Op = strings.TrimSpace(c.Op)
				switch c.Op {
				case "eq", "ne", "gt", "gte", "lt", "lte", "nonempty", "empty":
				default:
					return plan{}, fmt.Errorf("paso %d: operador show_if desconocido: %s", i+1, c.Op)
				}
				if c.Field == "" {
					return plan{}, fmt.Errorf("paso %d: show_if sin campo en %s", i+1, in.Name)
				}
				prev := false
				for x := 0; x < j; x++ {
					if p.Steps[i].Inputs[x].Name == c.Field {
						prev = true
						break
					}
				}
				if !prev {
					return plan{}, fmt.Errorf("paso %d: show_if de %s referencia campo no previo: %s", i+1, in.Name, c.Field)
				}
			}
		}
	}
	if p.Title == "" {
		p.Title = "INSTALACIÓN"
	}
	return p, nil
}

// evalCondition evalúa una condición show_if contra los valores ya capturados.
// Las comparaciones numéricas devuelven false si alguno no es un entero.
func evalCondition(c inputCondition, vals map[string]string) bool {
	v := strings.TrimSpace(vals[c.Field])
	switch c.Op {
	case "eq":
		return v == c.Value
	case "ne":
		return v != c.Value
	case "nonempty":
		return v != ""
	case "empty":
		return v == ""
	case "gt", "gte", "lt", "lte":
		a, ea := strconv.Atoi(v)
		b, eb := strconv.Atoi(strings.TrimSpace(c.Value))
		if ea != nil || eb != nil {
			return false
		}
		switch c.Op {
		case "gt":
			return a > b
		case "gte":
			return a >= b
		case "lt":
			return a < b
		default:
			return a <= b
		}
	}
	return false
}

// inputVisible indica si un campo cumple todas sus condiciones show_if.
func inputVisible(in planInput, vals map[string]string) bool {
	for _, c := range in.ShowIf {
		if !evalCondition(c, vals) {
			return false
		}
	}
	return true
}

// visibleInputs devuelve los campos cuyas condiciones show_if se cumplen
// con los valores respondidos hasta ahora.
func visibleInputs(inputs []planInput, vals map[string]string) []planInput {
	out := make([]planInput, 0, len(inputs))
	for _, in := range inputs {
		if inputVisible(in, vals) {
			out = append(out, in)
		}
	}
	return out
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
	maxStepLogs = 400
	maxLineLen  = 400
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
	ctxDoneMsg   struct{}
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

// killGroup pide al grupo del proceso que termine y, si sigue vivo tras un
// margen, lo mata. Sin la escalada, `apt-get`/`npm` pueden quedar huérfanos
// reteniendo el lock del gestor de paquetes.
func killGroup(c *exec.Cmd) {
	if c.Process == nil {
		return
	}
	pgid := c.Process.Pid
	if g, err := syscall.Getpgid(c.Process.Pid); err == nil && g > 0 {
		pgid = g
	}
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	_ = syscall.Kill(-pgid, syscall.SIGCONT)
	go func(pgid int) {
		time.Sleep(3 * time.Second)
		// Solo si el grupo sigue existiendo (evita matar un pgid reutilizado).
		if err := syscall.Kill(-pgid, 0); err == nil {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
	}(pgid)
}

// runCmd arranca c y lo mata (con escalada) si ctx se cancela.
func runCmd(ctx context.Context, c *exec.Cmd) error {
	if err := c.Start(); err != nil {
		return err
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			killGroup(c)
		case <-done:
		}
	}()
	err := c.Wait()
	close(done)
	return err
}

// ---------------------------------------------------------------- modelo

type stepsModel struct {
	plan       plan
	steps      []runStep
	cursor     int
	current    int
	pinned     int
	canceled   bool
	finished   bool
	showHelp   bool
	showSteps  bool // al terminar: alternar entre reporte y lista de pasos
	focusSteps bool // con formulario abierto: foco en la lista de pasos

	width  int
	height int

	startedAt time.Time
	elapsed   time.Duration

	logDir   string
	stateDir string
	run      *runner
	ctx      context.Context

	// keyCache evita leer archivos de claves en cada repintado (View).
	keyCache map[string]string

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
		progress.WithSolidFill(themePurple),
		progress.WithFillCharacters('█', '░'),
	)
	prog.EmptyColor = themeCurrent

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
		ctx:       context.Background(),
		keyCache:  map[string]string{},
		startedAt: time.Now(),
		spinner:   sp,
		progress:  prog,
		input:     ti,
	}
}

func (m stepsModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.startStep(0), waitCtx(m.ctx))
}

// waitCtx convierte SIGTERM/SIGINT externos en un mensaje del event loop.
func waitCtx(ctx context.Context) tea.Cmd {
	return func() tea.Msg {
		<-ctx.Done()
		return ctxDoneMsg{}
	}
}

func (m stepsModel) startStep(idx int) tea.Cmd {
	return func() tea.Msg { return startStepMsg{idx: idx} }
}

func (m stepsModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case ctxDoneMsg:
		if m.current >= 0 && m.current < len(m.steps) && m.steps[m.current].state == stRunning {
			m.run.kill()
		}
		m.markCanceled()
		m.canceled = true
		if !m.finished {
			m.finished = true
			m.elapsed = time.Since(m.startedAt)
		}
		return m, tea.Quit

	case tea.KeyMsg:
		// ctrl+↑/↓ navega los pasos incluso desde el formulario.
		if m.formActive {
			switch msg.String() {
			case "ctrl+up":
				m.focusSteps = true
				if m.cursor > 0 {
					m.cursor--
				}
				return m, nil
			case "ctrl+down":
				m.focusSteps = true
				if m.cursor < len(m.steps)-1 {
					m.cursor++
				}
				return m, nil
			}
		}
		if m.formActive && !m.focusSteps {
			return m.handleFormKey(msg)
		}
		if m.finished && !m.showSteps {
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
	case "esc":
		if m.formActive && m.focusSteps {
			m.focusSteps = false
			return m, nil
		}
		fallthrough
	case "q", "ctrl+c":
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

	case "tab":
		if m.formActive && m.focusSteps {
			m.focusSteps = false
		} else if m.finished {
			m.showSteps = false
		}

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
	case "tab":
		m.showSteps = true
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
	m.focusSteps = false
	m.formIdx = 0
	m.formVals = map[string]string{}
	m.formSel = map[int]bool{}
	for _, in := range m.plan.Steps[idx].Inputs {
		if in.Type == "confirm" {
			def := in.Default == "true" || in.Default == "y" || in.Default == "s"
			m.formVals[in.Name] = strconv.FormatBool(def)
		}
	}
	vis := visibleInputs(m.plan.Steps[idx].Inputs, m.formVals)
	if len(vis) == 0 {
		return m.finishForm(idx)
	}
	m.prepareField(vis[0])
	return m, nil
}

// prepareField prepara el campo activo. Si ya tiene un valor guardado (porque
// se volvió a él) lo restaura en lugar de usar el default.
func (m *stepsModel) prepareField(in planInput) {
	m.input.SetValue("")
	m.input.Placeholder = in.Default
	m.input.EchoMode = textinput.EchoNormal
	if in.Type == "password" {
		m.input.EchoMode = textinput.EchoPassword
	}
	stored, has := m.formVals[in.Name]
	switch in.Type {
	case "input", "password":
		val := in.Default
		if has {
			val = stored
		}
		m.input.SetValue(val)
	case "confirm":
		yes := in.Default == "true" || in.Default == "y" || in.Default == "s"
		if has {
			yes = stored == "true"
		}
		m.confirmYes = yes
		m.formVals[in.Name] = strconv.FormatBool(yes)
	case "select":
		m.formCursor = 0
		m.formSel = map[int]bool{}
		val := in.Default
		if has {
			val = stored
		}
		first := -1
		for i, opt := range in.Options {
			if strings.Contains("\n"+val+"\n", "\n"+opt+"\n") {
				m.formSel[i] = true
				if first < 0 {
					first = i
				}
			}
		}
		if first >= 0 {
			m.formCursor = first
		}
	case "key":
		// La lectura se hace al entrar al campo, no en cada repintado.
		m.loadKey(in)
	}
	m.input.Focus()
}

// loadKey guarda en cache el contenido de la clave que muestra el formulario.
func (m *stepsModel) loadKey(in planInput) {
	if m.keyCache == nil {
		m.keyCache = map[string]string{}
	}
	if data, err := os.ReadFile(expandPath(in.Path)); err == nil {
		m.keyCache[in.Path] = string(data)
	} else {
		m.keyCache[in.Path] = ""
	}
}

// storeField guarda el valor del campo activo antes de cambiar de campo, para
// no perder lo escrito al retroceder.
func (m *stepsModel) storeField(in planInput) {
	switch in.Type {
	case "input", "password":
		m.formVals[in.Name] = m.input.Value()
	case "confirm":
		m.formVals[in.Name] = strconv.FormatBool(m.confirmYes)
	case "select":
		var vals []string
		for i, opt := range in.Options {
			if m.formSel[i] {
				vals = append(vals, opt)
			}
		}
		m.formVals[in.Name] = strings.Join(vals, "\n")
	}
}

// backForm retrocede al campo visible anterior, conservando los valores.
func (m stepsModel) backForm(idx int) (tea.Model, tea.Cmd) {
	if m.formIdx <= 0 {
		return m, nil
	}
	inputs := visibleInputs(m.plan.Steps[idx].Inputs, m.formVals)
	m.formIdx--
	if m.formIdx >= len(inputs) {
		m.formIdx = len(inputs) - 1
	}
	m.prepareField(inputs[m.formIdx])
	return m, nil
}

func (m stepsModel) handleFormKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	idx := m.current
	if idx < 0 || idx >= len(m.plan.Steps) {
		m.formActive = false
		return m, nil
	}
	inputs := visibleInputs(m.plan.Steps[idx].Inputs, m.formVals)
	if m.formIdx >= len(inputs) {
		m.formActive = false
		return m, nil
	}
	in := inputs[m.formIdx]

	if msg.String() == "tab" {
		m.focusSteps = true
		return m, nil
	}

	// Retroceso entre campos: shift+tab siempre; ↑ salvo en select (donde
	// mueve la opción); ← en select. No se usa "k": es texto válido en inputs.
	back := msg.String() == "shift+tab"
	if !back {
		switch in.Type {
		case "select":
			back = msg.String() == "left"
		default:
			back = msg.String() == "up"
		}
	}
	if back {
		m.storeField(in)
		return m.backForm(idx)
	}

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
			m.storeField(in)
			return m.advanceForm(idx)
		}
		return m, cmd

	case "confirm":
		switch msg.String() {
		case "left", "right", "h", "l", " ", "x":
			cur := m.formVals[in.Name] == "true"
			m.confirmYes = !cur
			m.formVals[in.Name] = strconv.FormatBool(m.confirmYes)
		case "y", "Y", "s", "S":
			m.confirmYes = true
			m.storeField(in)
			return m.advanceForm(idx)
		case "n", "N":
			m.confirmYes = false
			m.storeField(in)
			return m.advanceForm(idx)
		case "enter":
			m.storeField(in)
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
			m.storeField(in)
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
	inputs := visibleInputs(m.plan.Steps[idx].Inputs, m.formVals)
	if m.formIdx+1 >= len(inputs) {
		return m.finishForm(idx)
	}
	m.formIdx++
	m.prepareField(inputs[m.formIdx])
	return m, nil
}

func (m stepsModel) finishForm(idx int) (tea.Model, tea.Cmd) {
	m.formActive = false
	// La escritura del resultado es pequeña y debe existir antes de que el paso
	// arranque; se hace aquí (no en View ni en el bucle de ejecución).
	m.writeResults(idx, m.resultsContent(idx))
	ps := m.plan.Steps[idx]
	if ps.Interactive {
		c := exec.Command("bash", "-c", ps.Cmd)
		c.Env = m.stepEnv(idx, "TERM=xterm-256color")
		return m, tea.ExecProcess(c, func(err error) tea.Msg {
			return stepDoneMsg{idx: idx, err: err}
		})
	}
	return m, tea.Batch(
		tea.ClearScreen,
		m.execStep(idx),
		tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
			return stepTickMsg{idx: idx}
		}),
	)
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

// resultsContent serializa los valores del formulario en formato KEY='valor'.
func (m stepsModel) resultsContent(idx int) string {
	vis := visibleInputs(m.plan.Steps[idx].Inputs, m.formVals)
	shown := make(map[string]bool, len(vis))
	for _, in := range vis {
		shown[in.Name] = true
	}
	var b strings.Builder
	for _, in := range m.plan.Steps[idx].Inputs {
		val := m.formVals[in.Name]
		if !shown[in.Name] {
			val = "" // campo oculto: no debe heredar valores del entorno
		}
		b.WriteString(in.Name + "=" + shellQuote(val) + "\n")
	}
	return b.String()
}

// writeResults escribe los valores del formulario en $NUI_STATE_DIR.
func (m stepsModel) writeResults(idx int, content string) {
	if m.stateDir == "" || content == "" {
		return
	}
	_ = os.MkdirAll(m.stateDir, 0o700)
	_ = os.WriteFile(filepath.Join(m.stateDir, fmt.Sprintf("result-%02d.env", idx+1)),
		[]byte(content), 0o600)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func (m stepsModel) stepEnv(idx int, extra ...string) []string {
	env := append(os.Environ(), "TERM=dumb", "NO_COLOR=1", "CLICOLOR=0")
	if m.stateDir != "" {
		env = append(env, "NUI_STATE_DIR="+m.stateDir,
			fmt.Sprintf("NUI_STEP_RESULT=%s", filepath.Join(m.stateDir, fmt.Sprintf("result-%02d.env", idx+1))))
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
		c.Env = m.stepEnv(idx, "TERM=xterm-256color")
		return m, tea.ExecProcess(c, func(err error) tea.Msg {
			return stepDoneMsg{idx: idx, err: err}
		})
	}

	return m, tea.Batch(
		tea.ClearScreen,
		m.execStep(idx),
		tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg {
			return stepTickMsg{idx: idx}
		}),
	)
}

// execStep es un tea.Cmd: arranca el comando, transmite su salida al panel
// línea a línea y devuelve stepDoneMsg al terminar. No bloquea el event loop.
func (m stepsModel) execStep(idx int) tea.Cmd {
	ps := m.plan.Steps[idx]
	logPath := m.logPath(idx)
	env := m.stepEnv(idx)
	run := m.run

	return func() tea.Msg {
		logFile, err := os.Create(logPath)
		if err != nil {
			logFile = nil
		}
		defer func() {
			if logFile != nil {
				_ = logFile.Close()
			}
		}()

		c := exec.Command("bash", "-c", ps.Cmd)
		c.Env = env
		c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

		pr, pw := io.Pipe()
		c.Stdout = pw
		c.Stderr = pw

		readerDone := make(chan struct{})
		go func() {
			defer close(readerDone)
			sc := bufio.NewScanner(pr)
			sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
			for sc.Scan() {
				line := sc.Text()
				if logFile != nil {
					fmt.Fprintln(logFile, line)
				}
				sendToProgram(lineMsg{idx: idx, line: line})
			}
		}()

		if err := c.Start(); err != nil {
			pw.Close()
			<-readerDone
			run.clear()
			return stepDoneMsg{idx: idx, err: err}
		}
		run.setCmd(c)

		err = c.Wait()
		pw.Close() // el scanner termina y entrega lo pendiente
		<-readerDone
		run.clear()
		return stepDoneMsg{idx: idx, err: err}
	}
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
	// Nanosegundos + PID: dos ejecuciones simultaneas no comparten log.
	return filepath.Join(m.logDir, fmt.Sprintf("steps-%s-%d-%02d-%s.log",
		time.Now().Format("20060102-150405.000000000"), os.Getpid(), idx+1, slug))
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
	stPanelBoxFocus = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).
			BorderForeground(colAccent).Padding(0, 1)
	stPinMark = lipgloss.NewStyle().Foreground(colAccent).Bold(true)
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

// rightPanelBox resalta el panel derecho salvo cuando el foco está en la
// lista de pasos mientras hay un formulario abierto.
func (m stepsModel) rightPanelBox() lipgloss.Style {
	if m.formActive && m.focusSteps {
		return stPanelBox
	}
	return stPanelBoxFocus
}

func (m stepsModel) View() string {
	// Terminales muy pequeñas o sin tamaño conocido: no se dibuja nada para
	// evitar alturas negativas en los recortes.
	if m.width < 4 || m.height < 5 {
		return ""
	}
	// Margen defensivo: no escribir nunca en la ultima celda (esquina inferior
	// derecha). Terminales con auto-wrap inmediato hacen scroll y corrompen el
	// frame; con columna derecha y fila inferior vacias eso es imposible.
	w, h := m.width-1, m.height-1
	if m.showHelp {
		return normalizeView(m.viewHelp(), w, h)
	}

	bodyH := maxInt(1, h-2)
	leftW := clampInt(int(float64(w)*0.40), 20, 40)
	if leftW > w-3 {
		leftW = maxInt(1, w/3)
	}
	rightW := maxInt(1, w-leftW-2)

	var right string
	switch {
	case m.formActive && !m.focusSteps:
		right = m.viewForm(rightW, bodyH)
	case m.finished && !m.showSteps:
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
	if w < 1 {
		w = 1
	}
	if h < 0 {
		h = 0
	}
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
	title := m.plan.Title
	if m.formActive && m.focusSteps {
		title = "▸ " + title
	}
	lines = append(lines, stHeader.Render(truncate(title, w)))
	lines = append(lines, "")

	rows := h - 2
	if rows < 1 {
		rows = 1
	}
	start := 0
	if len(m.steps) > rows {
		focus := m.viewIndex()
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
		if i == m.cursor && (!m.finished || m.showSteps) {
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

		pin := "  "
		if i == m.pinned {
			pin = stPinMark.Render("◆ ")
		}
		label := truncate(fmt.Sprintf("%d. %s", i+1, s.title), w-8)
		lines = append(lines, cursor+" "+marker+" "+pin+titleStyle.Render(label))
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
	return m.rightPanelBox().Width(w - 2).Height(h - 2).Render(content)
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
	inputs := visibleInputs(ps.Inputs, m.formVals)
	if m.formIdx >= len(inputs) {
		return ""
	}

	head := []string{
		stHeader.Render(truncate(fmt.Sprintf("%s · formulario · campo %d de %d",
			ps.Title, m.formIdx+1, len(inputs)), innerW)),
		"",
	}
	lines := make([]string, 0, len(inputs)*3)
	activeLine := 0
	for i, in := range inputs {
		if i == m.formIdx {
			activeLine = len(lines)
		}
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
			// Un select inactivo debe mostrar su propio valor guardado, no el
			// formSel/formCursor del campo activo.
			sel, cursorOpt := m.formSel, m.formCursor
			if !active {
				val := m.formVals[in.Name]
				sel = map[int]bool{}
				cursorOpt = 0
				first := -1
				for i, opt := range in.Options {
					if strings.Contains("\n"+val+"\n", "\n"+opt+"\n") {
						sel[i] = true
						if first < 0 {
							first = i
						}
					}
				}
				if first >= 0 {
					cursorOpt = first
				}
			}
			maxOpts := innerH - 10
			if maxOpts < 5 {
				maxOpts = 5
			}
			start, end := 0, len(in.Options)
			if len(in.Options) > maxOpts {
				start = 0
				if cursorOpt >= maxOpts {
					start = cursorOpt - maxOpts + 1
				}
				end = start + maxOpts
				if end > len(in.Options) {
					end = len(in.Options)
					start = maxInt(0, end-maxOpts)
				}
			}
			for oi := start; oi < end; oi++ {
				mark := stPendMark.Render("[ ]")
				if sel[oi] {
					mark = stDoneMark.Render("[x]")
				}
				cur := "  "
				if active && oi == cursorOpt {
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
			path := expandPath(in.Path)
			data, ok := m.keyCache[in.Path]
			if !ok {
				if b, err := os.ReadFile(path); err == nil {
					data = string(b)
				}
			}
			if data == "" {
				lines = append(lines, prefix+"  "+stFaint.Render(truncate("(sin generar: el paso de identidad no creo esta clave)", maxInt(0, innerW-4))))
			} else {
				text := strings.TrimRight(data, "\n")
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

	hint := "[enter] siguiente · [shift+tab] anterior · [tab] pasos · [esc] cancelar"
	if ps.Optional {
		hint = "[enter] siguiente · [shift+tab] anterior · [tab] pasos · [esc] omitir"
	}

	// Ventana desplazable: mantiene visible el campo activo aunque haya más
	// campos de los que caben (por ejemplo con 2 o 3 cuentas adicionales).
	maxLines := maxInt(1, innerH-2)
	bodyMax := maxInt(1, maxLines-3) // cabecera (2) + pista (1)
	if len(lines) > bodyMax {
		start := activeLine - bodyMax/2
		if start < 0 {
			start = 0
		}
		if start+bodyMax > len(lines) {
			start = len(lines) - bodyMax
		}
		lines = lines[start : start+bodyMax]
	}
	lines = append(append(head, lines...), stFaint.Render(truncate(hint, innerW)))
	if len(lines) > maxLines {
		lines = lines[:maxLines]
	}
	return m.rightPanelBox().Width(w - 2).Height(h - 2).Render(strings.Join(lines, "\n"))
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
	return m.rightPanelBox().Width(w - 2).Height(h - 2).Render(strings.Join(lines, "\n"))
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
	// El cursor manda: se puede inspeccionar cualquier paso, incluso el que
	// se esta ejecutando o los ya terminados, sin quedar anclado al activo.
	if m.cursor >= 0 && m.cursor < len(m.steps) {
		return m.cursor
	}
	if m.current >= 0 && m.current < len(m.steps) {
		return m.current
	}
	return 0
}

func (m stepsModel) viewFooter(w int) string {
	if m.formActive && m.focusSteps {
		keys := [][2]string{{"↑/↓", "navegar pasos"}, {"enter", "detalle"}, {"tab/esc", "volver al formulario"}, {"q", "salir"}}
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, stFootKey.Render("["+k[0]+"]")+" "+stFootTxt.Render(k[1]))
		}
		line := stFootTxt.Render("PASOS") + "  " + strings.Join(parts, stFootSep.Render(" • "))
		return lipgloss.NewStyle().MaxWidth(w).Render(" " + line)
	}
	if m.formActive {
		hint := "[enter] siguiente · [shift+tab] anterior · [tab] pasos · [esc] cancelar"
		if m.current >= 0 && m.current < len(m.plan.Steps) && m.plan.Steps[m.current].Optional {
			hint = "[enter] siguiente · [shift+tab] anterior · [tab] pasos · [esc] omitir"
		}
		return lipgloss.NewStyle().MaxWidth(w).Render(
			" " + stFootTxt.Render(truncate(hint, w-1)))
	}

	title := m.plan.Title
	var keys [][2]string
	if m.finished && !m.showSteps {
		title = "Logs: " + m.logDir
		keys = [][2]string{{"↑/↓", "desplazar"}, {"tab", "pasos"}, {"q", "salir"}, {"?", "ayuda"}}
	} else {
		if m.finished {
			title = "Pasos · [tab] reporte"
		}
		keys = [][2]string{{"↑/↓", "navegar"}, {"enter", "detalle"}, {"tab", "reporte"}, {"q", "salir"}, {"?", "ayuda"}}
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
		{"shift+tab", "campo anterior en el formulario (↑, ← en select)"},
		{"tab", "pasos desde el formulario / alternar reporte al terminar"},
		{"ctrl+↑/↓", "navegar pasos directamente desde el formulario"},
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

	w, h := maxInt(1, m.width-1), maxInt(1, m.height-1)
	placed := lipgloss.Place(w, maxInt(0, h-2), lipgloss.Center, lipgloss.Center, box)
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
		fmt.Fprintln(os.Stderr, `nui steps: uso: nui steps run --plan <archivo|-> [--log-dir DIR] [--plain] [--non-interactive] [--title T]`)
		return 2
	}
	args = args[1:]

	planPath := "-"
	logDir := os.Getenv("LOG_DIR")
	plain := false
	nonInteractive := false
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
		case "--non-interactive":
			nonInteractive = true
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
	_ = os.MkdirAll(logDir, 0o700)
	_ = os.Chmod(logDir, 0o700)

	p, err := loadPlan(planPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "nui steps:", err)
		return 2
	}
	if title != "" {
		p.Title = title
	}

	in, out, tty, closer := tuiIO()
	defer closer()
	w, h := termSize(out)

	stateDir, err := os.MkdirTemp("", "nui-steps-state-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "nui steps:", err)
		return 1
	}
	defer os.RemoveAll(stateDir)

	if plain || nonInteractive || !tty || w < 64 || h < 14 {
		return runPlanPlain(p, logDir, stateDir)
	}

	// SIGTERM/SIGHUP (kill, cierre de terminal) cancelan los pasos hijos.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()

	stepsProgram.Store(nil)
	m := newStepsModel(p, logDir)
	m.stateDir = stateDir
	m.ctx = ctx
	prog := tea.NewProgram(m,
		tea.WithInput(in),
		tea.WithOutput(out),
		tea.WithAltScreen(),
	)
	stepsProgram.Store(prog)

	final, err := prog.Run()
	stepsProgram.Store(nil)
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
// Se usa atomic.Pointer porque el runner escribe desde goroutines mientras
// cmdSteps puede limpiarlo al terminar (antes era una carrera con nil).
var stepsProgram atomic.Pointer[tea.Program]

// sendToProgram entrega un mensaje si hay programa activo (no-op si no).
func sendToProgram(msg tea.Msg) {
	if p := stepsProgram.Load(); p != nil {
		p.Send(msg)
	}
}

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

	// Ctrl+C / SIGTERM matan el grupo del paso actual (no deja apt/npm vivos).
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

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
			err = runCmd(ctx, c)
		} else {
			pr, pw := io.Pipe()
			c.Stdout, c.Stderr = pw, pw
			logFile, _ := os.Create(filepath.Join(logDir,
				fmt.Sprintf("steps-%s-%d-%02d-%s.log", start.Format("20060102-150405.000000000"), os.Getpid(), i+1, slugify(ps.Title))))
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
			err = runCmd(ctx, c)
			pw.Close()
			<-done
			if logFile != nil {
				logFile.Close()
			}
		}

		if ctx.Err() != nil {
			fmt.Println("[ERROR] interrumpido por el usuario")
			errs = append(errs, ps.Title+": interrumpido")
			break
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
	vals := map[string]string{}
	var b strings.Builder
	for _, in := range inputs {
		if !inputVisible(in, vals) {
			// Campo oculto: se guarda vacío para no heredar valores del entorno.
			vals[in.Name] = ""
			b.WriteString(in.Name + "=" + shellQuote("") + "\n")
			continue
		}
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
			path := expandPath(in.Path)
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
		vals[in.Name] = val
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

// expandPath expande ~ y variables de entorno en rutas del plan.
func expandPath(p string) string {
	p = os.ExpandEnv(p)
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(home, p[2:])
		}
	}
	return p
}

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
