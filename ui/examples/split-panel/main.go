// Split Status Panel — TUI minimalista para scripts de múltiples pasos.
//
// Ejecutar: go run main.go
//
// Layout:
//
//	┌ lista de pasos ────────┐  ╭ panel de estado ────────────────────────╮
//	  [✓] 1. Backup            │  ⠹ Desplegando aplicación               │
//	> [⠹] 2. Dependencias      │  [████████████░░░░░░░░░░]          60%  │
//	  [ ] 3. Migraciones       │                      (paso 3 de 5)       │
//	  [ ] 4. Cache y restart   │  ─────────────────────────────────────  │
//	  [ ] 5. Verificación      │  -> Conectado al servidor remoto        │
//	                           ╰─────────────────────────────────────────╯
//	────────────────────────────────────────────────────────────────────────
//	[↑/↓] navegar • [enter] seleccionar • [q] salir • [?] ayuda
package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ---------------------------------------------------------------------------
// Constantes: textos, ritmos y medidas del layout
// ---------------------------------------------------------------------------

const (
	appHeadline = "Desplegando aplicación"

	// Ritmo de la simulación asíncrona.
	frameEvery = 28 * time.Millisecond  // pausa entre frames de progreso
	frameStep  = 0.02                   // avance de progreso por frame
	stepPause  = 420 * time.Millisecond // pausa entre un paso y el siguiente

	// Layout.
	minWidth   = 64
	minHeight  = 14
	leftRatio  = 0.42 // 42% del ancho para la lista de pasos
	leftMin    = 30
	leftMax    = 42
	panelGap   = 2 // columnas entre panel izquierdo y derecho
	footerRows = 2 // regla + línea de atajos
	maxLogs    = 400
)

// ---------------------------------------------------------------------------
// Paleta
// ---------------------------------------------------------------------------

var (
	cMint   = lipgloss.AdaptiveColor{Light: "#0F7B5F", Dark: "#7FD1AE"} // completado
	cViolet = lipgloss.AdaptiveColor{Light: "#5B3FD1", Dark: "#B4A0F0"} // en ejecución
	cDim    = lipgloss.AdaptiveColor{Light: "#8C8C8C", Dark: "#6B6B6B"} // texto atenuado
	cFaint  = lipgloss.AdaptiveColor{Light: "#C2C2C2", Dark: "#3F3F3F"} // reglas
	cText   = lipgloss.AdaptiveColor{Light: "#1F1F1F", Dark: "#D6D6D6"} // texto normal
	cBorder = lipgloss.AdaptiveColor{Light: "#C8C8C8", Dark: "#4A4A4A"} // bordes
	cAccent = lipgloss.AdaptiveColor{Light: "#0B6BCB", Dark: "#7AA2F7"} // acentos
	cWarn   = lipgloss.AdaptiveColor{Light: "#A15C00", Dark: "#E5B567"} // avisos
)

// ---------------------------------------------------------------------------
// Estilos Lip Gloss
// ---------------------------------------------------------------------------

var (
	// Lista de pasos.
	styleCursor    = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	styleDone      = lipgloss.NewStyle().Foreground(cMint)
	styleRunning   = lipgloss.NewStyle().Foreground(cViolet)
	stylePending   = lipgloss.NewStyle().Foreground(cDim)
	styleTitleDone = lipgloss.NewStyle().Foreground(cMint)
	styleTitleRun  = lipgloss.NewStyle().Foreground(cText).Bold(true)
	styleTitlePend = lipgloss.NewStyle().Foreground(cDim)

	// Panel derecho.
	stylePanel     = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cBorder).Padding(0, 1)
	styleHeader    = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	styleHeaderDim = lipgloss.NewStyle().Foreground(cDim).Bold(true)
	styleBracket   = lipgloss.NewStyle().Foreground(cDim)
	stylePercent   = lipgloss.NewStyle().Foreground(cDim)
	styleCounter   = lipgloss.NewStyle().Foreground(cDim)
	styleLogArrow  = lipgloss.NewStyle().Foreground(cDim)
	styleLog       = lipgloss.NewStyle().Foreground(cText)
	styleFaint     = lipgloss.NewStyle().Foreground(cDim).Italic(true)

	// Footer y avisos.
	styleRule     = lipgloss.NewStyle().Foreground(cFaint)
	styleKey      = lipgloss.NewStyle().Foreground(cText)
	styleHint     = lipgloss.NewStyle().Foreground(cDim)
	styleSep      = lipgloss.NewStyle().Foreground(cFaint)
	styleTooSmall = lipgloss.NewStyle().Foreground(cWarn).Bold(true)

	// Ayuda.
	styleHelpBox   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cBorder).Padding(1, 3)
	styleHelpTitle = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
	styleHelpKey   = lipgloss.NewStyle().Foreground(cText).Bold(true)
)

// ---------------------------------------------------------------------------
// Modelo de datos
// ---------------------------------------------------------------------------

type state int

const (
	pending state = iota
	running
	done
)

// cue es una línea de salida programada dentro de un paso (at = 0..1).
type cue struct {
	at   float64
	text string
}

type step struct {
	title   string
	state   state
	percent float64
	logs    []string
	cues    []cue
}

// Mensajes propios del programa (arquitectura Elm).
type (
	// progressMsg llega desde el worker de cada paso.
	progressMsg struct {
		step    int
		percent float64
	}
	// logMsg añade una línea de salida al panel de detalle.
	logMsg struct {
		step int
		line string
	}
	// stepFinishedMsg cierra un paso (el worker cerró su canal).
	stepFinishedMsg struct{ step int }
	// startStepMsg arranca el siguiente paso tras una pausa.
	startStepMsg struct{ step int }
	// streamReadyMsg entrega el canal del worker al modelo.
	streamReadyMsg struct {
		step int
		ch   chan tea.Msg
	}
)

// Model es el estado completo de la TUI.
type Model struct {
	steps []step

	cursor  int // paso bajo el cursor
	current int // paso en ejecución (-1 si ninguno)
	pinned  int // paso fijado en el panel derecho (-1 = en vivo)

	stream    chan tea.Msg
	startedAt time.Time
	elapsed   time.Duration
	finished  bool
	showHelp  bool

	width  int
	height int

	spinner  spinner.Model
	progress progress.Model
}

// New construye el modelo con la secuencia de demo ya arrancada.
func New() Model {
	prog := progress.New(
		progress.WithoutPercentage(),
		progress.WithSolidFill("#8B7CF6"),
		progress.WithFillCharacters('█', '░'),
	)
	prog.EmptyColor = "#5B5F6B"

	sp := spinner.New()
	sp.Spinner = spinner.MiniDot
	sp.Style = styleRunning

	steps := demoSteps()
	steps[0].state = running

	return Model{
		steps:     steps,
		cursor:    0,
		current:   0,
		pinned:    -1,
		startedAt: time.Now(),
		spinner:   sp,
		progress:  prog,
	}
}

// demoSteps define la secuencia simulada de 5 tareas.
func demoSteps() []step {
	return []step{
		{
			title: "Respaldar archivos existentes",
			cues: []cue{
				{0.15, "Conectado al servidor remoto"},
				{0.42, "Empaquetando /etc y /var/lib/app"},
				{0.68, "Subiendo (6.4 MB/12 MB)"},
				{0.90, "Backup en /var/backups/app.tar.gz (12 MB)"},
			},
		},
		{
			title: "Instalar dependencias",
			cues: []cue{
				{0.18, "Resolviendo grafo de dependencias (14 paquetes)"},
				{0.45, "Descargando paquetes..."},
				{0.72, "Enlazando binarios en ~/.local/bin"},
				{0.92, "Dependencias al día"},
			},
		},
		{
			title: "Ejecutar migraciones de BD",
			cues: []cue{
				{0.20, "Conectando a postgres://localhost:5432/app"},
				{0.48, "Aplicando 002_add_indexes.sql"},
				{0.74, "Aplicando 003_backfill_sessions.sql"},
				{0.92, "Migraciones aplicadas (0 pendientes)"},
			},
		},
		{
			title: "Limpiar caché y reiniciar",
			cues: []cue{
				{0.22, "Flushing cache Redis (2.1 GB)"},
				{0.50, "Rotando logs de aplicación"},
				{0.76, "Reiniciando servicio worker"},
				{0.93, "Servicio activo (pid 4821)"},
			},
		},
		{
			title: "Verificar estado",
			cues: []cue{
				{0.28, "GET /healthz → 200 OK"},
				{0.58, "Comprobando versión de esquema 003"},
				{0.82, "Latencia p95: 84 ms"},
				{0.95, "Todo correcto"},
			},
		},
	}
}

// ---------------------------------------------------------------------------
// Ciclo de vida Bubble Tea
// ---------------------------------------------------------------------------

// Init arranca el spinner y el primer paso.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, dispatch(0, m.steps[0].cues))
}

// Update implementa la transición pura de estados.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
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

	case streamReadyMsg:
		m.stream = msg.ch
		return m, waitFor(msg.step, msg.ch)

	case progressMsg:
		if msg.step >= 0 && msg.step < len(m.steps) {
			m.steps[msg.step].percent = clamp01(msg.percent)
		}
		return m, m.waitNext(msg.step)

	case logMsg:
		if msg.step >= 0 && msg.step < len(m.steps) {
			s := &m.steps[msg.step]
			s.logs = append(s.logs, msg.line)
			if len(s.logs) > maxLogs {
				s.logs = s.logs[len(s.logs)-maxLogs:]
			}
		}
		return m, m.waitNext(msg.step)

	case stepFinishedMsg:
		next, cmd := m.finishStep(msg.step)
		return next, cmd

	case startStepMsg:
		next, cmd := m.begin(msg.step)
		return next, cmd
	}

	return m, nil
}

// handleKey resuelve la navegación y las salidas.
func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "esc", "ctrl+c":
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
		// Fija el paso bajo el cursor en el panel derecho; repetir lo suelta.
		if m.pinned == m.cursor {
			m.pinned = -1
		} else {
			m.pinned = m.cursor
		}

	case "r":
		if m.finished {
			next, cmd := m.reset()
			return next, cmd
		}
	}

	return m, nil
}

// begin pone un paso en ejecución y lanza su worker.
func (m Model) begin(i int) (Model, tea.Cmd) {
	if i < 0 || i >= len(m.steps) {
		return m, nil
	}
	m.current = i
	m.cursor = i
	m.pinned = -1
	m.steps[i].state = running
	m.steps[i].percent = 0
	m.steps[i].logs = nil
	return m, dispatch(i, m.steps[i].cues)
}

// finishStep cierra el paso, actualiza la lista y encadena el siguiente.
func (m Model) finishStep(i int) (Model, tea.Cmd) {
	if i >= 0 && i < len(m.steps) {
		m.steps[i].state = done
		m.steps[i].percent = 1
	}
	m.current = -1
	m.stream = nil

	if i+1 < len(m.steps) {
		return m, tea.Tick(stepPause, func(time.Time) tea.Msg {
			return startStepMsg{step: i + 1}
		})
	}

	m.finished = true
	m.elapsed = time.Since(m.startedAt)
	last := len(m.steps) - 1
	m.steps[last].logs = append(m.steps[last].logs,
		fmt.Sprintf("Despliegue completado en %.1fs", m.elapsed.Seconds()))
	if m.pinned < 0 {
		m.cursor = last
	}
	return m, nil
}

// waitNext vuelve a suscribirse al canal del paso en curso.
func (m Model) waitNext(step int) tea.Cmd {
	if m.stream == nil || step != m.current {
		return nil
	}
	return waitFor(step, m.stream)
}

// reset reinicia toda la secuencia (atajo "r").
func (m Model) reset() (Model, tea.Cmd) {
	m.steps = demoSteps()
	m.steps[0].state = running
	m.cursor, m.current, m.pinned = 0, 0, -1
	m.stream = nil
	m.finished = false
	m.showHelp = false
	m.elapsed = 0
	m.startedAt = time.Now()
	return m, dispatch(0, m.steps[0].cues)
}

// ---------------------------------------------------------------------------
// Worker asíncrono: un goroutine por paso que emite progreso y logs
// ---------------------------------------------------------------------------

// dispatch lanza el worker y devuelve su canal al modelo.
func dispatch(idx int, cues []cue) tea.Cmd {
	return func() tea.Msg {
		ch := make(chan tea.Msg, 64)
		go runStep(idx, cues, ch)
		return streamReadyMsg{step: idx, ch: ch}
	}
}

// runStep simula el trabajo real emitiendo frames de progreso y líneas.
func runStep(idx int, cues []cue, ch chan<- tea.Msg) {
	defer close(ch)

	p := 0.0
	advance := func(target float64) {
		target = clamp01(target)
		for p+frameStep < target {
			p += frameStep
			ch <- progressMsg{step: idx, percent: p}
			time.Sleep(frameEvery)
		}
		if target > p {
			p = target
			ch <- progressMsg{step: idx, percent: p}
			time.Sleep(frameEvery)
		}
	}

	for _, c := range cues {
		advance(c.at)
		ch <- logMsg{step: idx, line: c.text}
	}
	advance(1)
}

// waitFor espera el siguiente mensaje del worker; al cerrarse el canal
// produce stepFinishedMsg.
func waitFor(step int, ch <-chan tea.Msg) tea.Cmd {
	return func() tea.Msg {
		if msg, ok := <-ch; ok {
			return msg
		}
		return stepFinishedMsg{step: step}
	}
}

// ---------------------------------------------------------------------------
// Vista
// ---------------------------------------------------------------------------

// View compone el frame completo.
func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}
	if m.width < minWidth || m.height < minHeight {
		msg := styleTooSmall.Render(truncate(fmt.Sprintf("Terminal pequeña: %dx%d", m.width, m.height), m.width))
		hint := styleFaint.Render(truncate(fmt.Sprintf("mínimo %dx%d · redimensiona la ventana", minWidth, minHeight), m.width))
		return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, msg+"\n"+hint)
	}
	if m.showHelp {
		return m.viewHelp()
	}

	bodyH := m.height - footerRows
	leftW := clamp(int(float64(m.width)*leftRatio), leftMin, leftMax)
	rightW := m.width - leftW - panelGap

	body := lipgloss.JoinHorizontal(lipgloss.Top,
		m.viewSteps(leftW, bodyH),
		strings.Repeat(" ", panelGap),
		m.viewPanel(rightW, bodyH),
	)

	return lipgloss.JoinVertical(lipgloss.Left,
		body,
		styleRule.Render(strings.Repeat("─", m.width)),
		m.viewFooter(),
	)
}

// viewSteps pinta la lista vertical de pasos.
func (m Model) viewSteps(w, h int) string {
	lines := make([]string, 0, len(m.steps))
	for i, s := range m.steps {
		cursor := " "
		if i == m.cursor && !m.finished {
			cursor = styleCursor.Render(">")
		}

		// El texto se trunca antes de aplicar color para no cortar secuencias.
		label := truncate(fmt.Sprintf("%d. %s", i+1, s.title), w-6)

		var marker, title string
		switch s.state {
		case done:
			marker = styleDone.Render("[✓]")
			title = styleTitleDone.Render(label)
		case running:
			marker = styleRunning.Render("[" + m.spinner.View() + "]")
			title = styleTitleRun.Render(label)
		default:
			marker = stylePending.Render("[ ]")
			if i == m.cursor && !m.finished {
				title = lipgloss.NewStyle().Foreground(cText).Render(label)
			} else {
				title = styleTitlePend.Render(label)
			}
		}

		lines = append(lines, cursor+" "+marker+" "+title)
	}

	// La lista ocupa como máximo la altura del cuerpo.
	if len(lines) > h {
		lines = lines[:h]
	}
	content := strings.Join(lines, "\n")
	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}

// viewPanel pinta el panel derecho: encabezado, progreso, contador y logs.
func (m Model) viewPanel(w, h int) string {
	innerW := max(0, w-4) // borde (2) + padding (2)
	innerH := max(0, h-2) // borde (2)

	idx := m.viewIndex()
	var cur step
	if idx >= 0 && idx < len(m.steps) {
		cur = m.steps[idx]
	}

	// Encabezado: spinner + acción en curso (o detalle de un paso fijado).
	title, titleStyle := appHeadline, styleHeader
	switch {
	case m.pinned >= 0 && m.pinned != m.naturalIndex():
		title, titleStyle = "Detalle del paso", styleHeaderDim
	case m.finished:
		title = fmt.Sprintf("Despliegue completado en %.1fs", m.elapsed.Seconds())
		titleStyle = styleHeaderDim
	}
	prefix := "  "
	if cur.state == running {
		prefix = m.spinner.View() + " "
	}
	header := prefix + titleStyle.Render(truncate(title, innerW-2))

	// Barra de progreso + porcentaje.
	barW := innerW - 7 // "[" + barra + "]" + " " + "100%"
	if barW < 8 {
		barW = 8
	}
	prog := m.progress
	prog.Width = barW
	pct := clamp01(cur.percent)
	bar := lipgloss.JoinHorizontal(lipgloss.Center,
		styleBracket.Render("["),
		prog.ViewAs(pct),
		styleBracket.Render("]"),
		" ",
		stylePercent.Render(fmt.Sprintf("%3.0f%%", pct*100)),
	)

	// Contador de paso, alineado a la derecha (con pista si hay uno fijado).
	stepNo := idx + 1
	if stepNo < 1 {
		stepNo = 1
	}
	counterText := fmt.Sprintf("(paso %d de %d)", stepNo, len(m.steps))
	if hint := " · enter para volver"; m.pinned >= 0 && len(counterText)+len(hint) <= innerW {
		counterText += hint
	}
	counter := styleCounter.Width(innerW).Align(lipgloss.Right).Render(counterText)

	divider := styleRule.Render(strings.Repeat("─", innerW))

	// Logs: últimas líneas del paso observado.
	rows := innerH - 4
	if rows < 1 {
		rows = 1
	}
	logs := make([]string, 0, rows)
	for _, line := range tail(cur.logs, rows) {
		logs = append(logs, styleLogArrow.Render("-> ")+
			styleLog.Render(truncate(line, innerW-3)))
	}
	for len(logs) < rows {
		if len(logs) == 0 && len(cur.logs) == 0 {
			log := styleFaint.Render("(esperando salida...)")
			if cur.state == pending {
				log = styleFaint.Render("(paso pendiente)")
			}
			logs = append(logs, log)
			continue
		}
		logs = append(logs, "")
	}
	if len(logs) > rows {
		logs = logs[len(logs)-rows:]
	}

	content := strings.Join(append([]string{header, bar, counter, divider}, logs...), "\n")
	return stylePanel.Width(w - 2).Height(h - 2).Render(content)
}

// naturalIndex es el paso que corresponde mostrar sin fijar ninguno.
func (m Model) naturalIndex() int {
	switch {
	case m.current >= 0:
		return m.current
	case m.finished:
		return len(m.steps) - 1
	default:
		return m.cursor
	}
}

// viewIndex decide qué paso se muestra en el panel derecho.
func (m Model) viewIndex() int {
	if m.pinned >= 0 {
		return m.pinned
	}
	return m.naturalIndex()
}

// viewFooter pinta la barra inferior de atajos.
func (m Model) viewFooter() string {
	keys := [][2]string{
		{"↑/↓", "navegar"},
		{"enter", "seleccionar"},
		{"q", "salir"},
		{"?", "ayuda"},
	}
	if m.finished {
		keys = [][2]string{
			{"r", "reiniciar"},
			{"q", "salir"},
			{"?", "ayuda"},
		}
	}

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, styleKey.Render("["+k[0]+"]")+" "+styleHint.Render(k[1]))
	}
	return " " + strings.Join(parts, styleSep.Render(" • "))
}

// viewHelp muestra la ayuda superpuesta al cuerpo.
func (m Model) viewHelp() string {
	rows := [][2]string{
		{"↑/↓ j/k", "navegar por la lista de pasos"},
		{"enter", "fijar / soltar el detalle de un paso"},
		{"r", "reiniciar la ejecución al terminar"},
		{"esc q", "salir"},
		{"?", "cerrar esta ayuda"},
	}

	keyCol := lipgloss.NewStyle().Foreground(cText).Bold(true).Width(9)
	lines := make([]string, 0, len(rows))
	maxW := 0
	for _, r := range rows {
		line := keyCol.Render(r[0]) + styleHint.Render(r[1])
		if w := lipgloss.Width(line); w > maxW {
			maxW = w
		}
		lines = append(lines, line)
	}

	// Width incluye el padding: contenido = Width - 2*3.
	boxW := min(maxW+6, max(24, m.width-2))
	box := styleHelpBox.Width(boxW).Render(strings.Join([]string{
		styleHelpTitle.Render("Atajos de teclado"),
		"",
		strings.Join(lines, "\n"),
		"",
		styleFaint.Render("pulsa ? para volver"),
	}, "\n"))

	placed := lipgloss.Place(m.width, m.height-footerRows, lipgloss.Center, lipgloss.Center, box)
	return lipgloss.JoinVertical(lipgloss.Left,
		placed,
		styleRule.Render(strings.Repeat("─", m.width)),
		m.viewFooter(),
	)
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// truncate recorta por runas añadiendo una elipsis.
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

// tail devuelve las últimas n entradas del slice.
func tail(s []string, n int) []string {
	if n <= 0 {
		return nil
	}
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

func main() {
	p := tea.NewProgram(New(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		panic(err)
	}
}
