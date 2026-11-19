package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestEvalCondition(t *testing.T) {
	vals := map[string]string{
		"acc_count":     "2",
		"acc1_espacio":  "Nuxiba",
		"acc2_espacio":  "   ",
		"acc1_platform": "github",
	}

	cases := []struct {
		name string
		cond inputCondition
		want bool
	}{
		{"eq ok", inputCondition{Field: "acc1_platform", Op: "eq", Value: "github"}, true},
		{"eq fail", inputCondition{Field: "acc1_platform", Op: "eq", Value: "bitbucket"}, false},
		{"ne ok", inputCondition{Field: "acc1_platform", Op: "ne", Value: "bitbucket"}, true},
		{"nonempty ok", inputCondition{Field: "acc1_espacio", Op: "nonempty"}, true},
		{"nonempty espacios", inputCondition{Field: "acc2_espacio", Op: "nonempty"}, false},
		{"empty ok", inputCondition{Field: "acc2_espacio", Op: "empty"}, true},
		{"empty fail", inputCondition{Field: "acc1_espacio", Op: "empty"}, false},
		{"gte true", inputCondition{Field: "acc_count", Op: "gte", Value: "2"}, true},
		{"gte false", inputCondition{Field: "acc_count", Op: "gte", Value: "3"}, false},
		{"gt true", inputCondition{Field: "acc_count", Op: "gt", Value: "1"}, true},
		{"gt false", inputCondition{Field: "acc_count", Op: "gt", Value: "2"}, false},
		{"lt false", inputCondition{Field: "acc_count", Op: "lt", Value: "2"}, false},
		{"lte true", inputCondition{Field: "acc_count", Op: "lte", Value: "2"}, true},
		{"no entero", inputCondition{Field: "acc1_espacio", Op: "gte", Value: "1"}, false},
		{"campo ausente", inputCondition{Field: "nope", Op: "eq", Value: ""}, true},
		{"op desconocida", inputCondition{Field: "acc_count", Op: "xxx", Value: "1"}, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := evalCondition(tc.cond, vals); got != tc.want {
				t.Fatalf("evalCondition(%+v) = %v, quiere %v", tc.cond, got, tc.want)
			}
		})
	}
}

func TestVisibleInputs(t *testing.T) {
	inputs := []planInput{
		{Name: "count", Prompt: "Cuentas"},
		{Name: "acc1_espacio", Prompt: "Espacio 1", ShowIf: []inputCondition{
			{Field: "count", Op: "gte", Value: "1"},
		}},
		{Name: "acc1_name", Prompt: "Nombre 1", ShowIf: []inputCondition{
			{Field: "count", Op: "gte", Value: "1"},
			{Field: "acc1_espacio", Op: "nonempty"},
		}},
		{Name: "acc2_espacio", Prompt: "Espacio 2", ShowIf: []inputCondition{
			{Field: "count", Op: "gte", Value: "2"},
		}},
	}

	cases := []struct {
		name string
		vals map[string]string
		want []string
	}{
		{"cero", map[string]string{"count": "0"}, []string{"count"}},
		{"uno sin espacio", map[string]string{"count": "1", "acc1_espacio": ""}, []string{"count", "acc1_espacio"}},
		{"uno con espacio", map[string]string{"count": "1", "acc1_espacio": "Nuxiba"}, []string{"count", "acc1_espacio", "acc1_name"}},
		{"dos", map[string]string{"count": "2", "acc1_espacio": "Nuxiba"}, []string{"count", "acc1_espacio", "acc1_name", "acc2_espacio"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := []string{}
			for _, in := range visibleInputs(inputs, tc.vals) {
				got = append(got, in.Name)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("visibleInputs = %v, quiere %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("visibleInputs = %v, quiere %v", got, tc.want)
				}
			}
		})
	}
}

func TestLoadPlanShowIf(t *testing.T) {
	valid := `{"title":"T","steps":[{"title":"S","cmd":"true","inputs":[
		{"type":"input","name":"count","prompt":"C","default":"0"},
		{"type":"input","name":"name","prompt":"N","show_if":[{"field":"count","op":"gte","value":"1"}]}
	]}]}`

	dir := t.TempDir()
	write := func(s string) string {
		t.Helper()
		p := filepath.Join(dir, "plan.json")
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}

	p, err := loadPlan(write(valid))
	if err != nil {
		t.Fatalf("plan valido rechazado: %v", err)
	}
	got := p.Steps[0].Inputs[1].ShowIf
	if len(got) != 1 || got[0].Field != "count" || got[0].Op != "gte" || got[0].Value != "1" {
		t.Fatalf("show_if no parseado: %+v", got)
	}

	invalid := []struct {
		name string
		json string
	}{
		{"op desconocida", `{"steps":[{"cmd":"true","inputs":[{"type":"input","name":"a"},{"type":"input","name":"b","show_if":[{"field":"a","op":"xxx"}]}]}]}`},
		{"campo no previo", `{"steps":[{"cmd":"true","inputs":[{"type":"input","name":"a","show_if":[{"field":"b","op":"eq","value":"1"}]},{"type":"input","name":"b"}]}]}`},
		{"campo vacio", `{"steps":[{"cmd":"true","inputs":[{"type":"input","name":"a","show_if":[{"op":"eq","value":"1"}]}]}]}`},
	}
	for _, tc := range invalid {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := loadPlan(write(tc.json)); err == nil {
				t.Fatal("plan invalido aceptado")
			}
		})
	}
}

// formPlan devuelve un plan con un formulario condicional de 4 campos.
func formPlan() plan {
	return plan{
		Title: "PRUEBA",
		Steps: []planStep{{
			Title: "Formulario",
			Cmd:   "true",
			Inputs: []planInput{
				{Type: "input", Name: "count", Prompt: "Cuentas", Default: "0"},
				{Type: "input", Name: "acc1_espacio", Prompt: "Espacio 1", ShowIf: []inputCondition{
					{Field: "count", Op: "gte", Value: "1"},
				}},
				{Type: "input", Name: "acc1_name", Prompt: "Nombre 1", ShowIf: []inputCondition{
					{Field: "count", Op: "gte", Value: "1"},
					{Field: "acc1_espacio", Op: "nonempty"},
				}},
				{Type: "input", Name: "acc2_espacio", Prompt: "Espacio 2", ShowIf: []inputCondition{
					{Field: "count", Op: "gte", Value: "2"},
				}},
			},
		}},
	}
}

func startFormModel(t *testing.T, p plan, dir string) stepsModel {
	t.Helper()
	base := newStepsModel(p, dir)
	base.stateDir = dir
	out, _ := base.startForm(0)
	m, ok := out.(stepsModel)
	if !ok {
		t.Fatal("startForm no devolvió stepsModel")
	}
	return m
}

func activeField(m stepsModel) string {
	vis := visibleInputs(m.plan.Steps[0].Inputs, m.formVals)
	if m.formIdx >= len(vis) {
		return ""
	}
	return vis[m.formIdx].Name
}

func typeValue(t *testing.T, m stepsModel, val string) stepsModel {
	t.Helper()
	m.input.SetValue(val)
	out, _ := m.handleFormKey(tea.KeyMsg{Type: tea.KeyEnter})
	next, ok := out.(stepsModel)
	if !ok {
		t.Fatal("handleFormKey no devolvió stepsModel")
	}
	return next
}

func pressForm(t *testing.T, m stepsModel, key tea.KeyMsg) stepsModel {
	t.Helper()
	out, _ := m.handleFormKey(key)
	next, ok := out.(stepsModel)
	if !ok {
		t.Fatal("handleFormKey no devolvió stepsModel")
	}
	return next
}

func pressModel(t *testing.T, m stepsModel, key tea.KeyMsg) stepsModel {
	t.Helper()
	out, _ := m.Update(key)
	next, ok := out.(stepsModel)
	if !ok {
		t.Fatal("Update no devolvió stepsModel")
	}
	return next
}

func readResult(t *testing.T, dir string) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "result-01.env"))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(raw), "\n") {
		if i := strings.IndexByte(line, '='); i > 0 {
			out[line[:i]] = strings.Trim(line[i+1:], "'")
		}
	}
	return out
}

func TestFormNavigationConditional(t *testing.T) {
	// count=0: el formulario termina después del primer campo.
	dir0 := t.TempDir()
	m := startFormModel(t, formPlan(), dir0)
	if activeField(m) != "count" {
		t.Fatalf("campo inicial = %q", activeField(m))
	}
	m = typeValue(t, m, "0")
	if m.formActive {
		t.Fatal("con count=0 el formulario debería terminar")
	}
	got0 := readResult(t, dir0)
	for _, name := range []string{"acc1_espacio", "acc1_name", "acc2_espacio"} {
		if got0[name] != "" {
			t.Fatalf("campo oculto %s = %q", name, got0[name])
		}
	}

	// count=1 con espacio: solo se piden los campos de la cuenta 1.
	dir1 := t.TempDir()
	m = startFormModel(t, formPlan(), dir1)
	m = typeValue(t, m, "1")
	if activeField(m) != "acc1_espacio" {
		t.Fatalf("tras count=1, campo = %q", activeField(m))
	}
	m = typeValue(t, m, "Nuxiba")
	if activeField(m) != "acc1_name" {
		t.Fatalf("tras espacio, campo = %q", activeField(m))
	}
	m = typeValue(t, m, "Pedro")
	if m.formActive {
		t.Fatal("el formulario debería terminar tras los campos de la cuenta 1")
	}
	got1 := readResult(t, dir1)
	if got1["count"] != "1" || got1["acc1_espacio"] != "Nuxiba" || got1["acc1_name"] != "Pedro" {
		t.Fatalf("resultado inesperado: %v", got1)
	}
	if got1["acc2_espacio"] != "" {
		t.Fatalf("acc2_espacio = %q, debe estar vacío", got1["acc2_espacio"])
	}

	// count=1 sin espacio: se ocultan los subcampos de la cuenta 1.
	dir2 := t.TempDir()
	m = startFormModel(t, formPlan(), dir2)
	m = typeValue(t, m, "1")
	m = typeValue(t, m, "")
	if m.formActive {
		t.Fatal("sin espacio no deben pedirse más campos")
	}
	got2 := readResult(t, dir2)
	if got2["acc1_espacio"] != "" || got2["acc1_name"] != "" {
		t.Fatalf("subcampos deberían estar vacíos: %v", got2)
	}
}

func TestFormBackKeepsValues(t *testing.T) {
	dir := t.TempDir()
	m := startFormModel(t, formPlan(), dir)
	m = typeValue(t, m, "1")

	// Escribir sin confirmar y retroceder no debe perder el valor.
	m.input.SetValue("Nuxiba")
	m = pressForm(t, m, tea.KeyMsg{Type: tea.KeyShiftTab})
	if activeField(m) != "count" {
		t.Fatalf("tras shift+tab, campo = %q", activeField(m))
	}
	if m.input.Value() != "1" {
		t.Fatalf("count restaurado = %q, quiere 1", m.input.Value())
	}
	m = typeValue(t, m, "1")
	if activeField(m) != "acc1_espacio" {
		t.Fatalf("al avanzar, campo = %q", activeField(m))
	}
	if m.input.Value() != "Nuxiba" {
		t.Fatalf("espacio restaurado = %q, quiere Nuxiba", m.input.Value())
	}

	// ↑ también retrocede en campos de texto.
	m = pressForm(t, m, tea.KeyMsg{Type: tea.KeyUp})
	if activeField(m) != "count" {
		t.Fatalf("tras ↑, campo = %q", activeField(m))
	}
	m = typeValue(t, m, "0")
	if m.formActive {
		t.Fatal("con count=0 tras volver, el formulario debe terminar")
	}
	got := readResult(t, dir)
	if got["count"] != "0" || got["acc1_espacio"] != "" {
		t.Fatalf("resultado inesperado: %v", got)
	}
}

func multiFormPlan() plan {
	p := formPlan()
	p.Steps = append(p.Steps,
		planStep{Title: "Paso 2", Cmd: "true"},
		planStep{Title: "Paso 3", Cmd: "true"},
	)
	return p
}

func TestFormToStepsFocus(t *testing.T) {
	dir := t.TempDir()
	m := startFormModel(t, multiFormPlan(), dir)
	m.input.SetValue("valor")
	if m.focusSteps {
		t.Fatal("el formulario debe empezar con el foco en los campos")
	}

	m = pressForm(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if !m.focusSteps {
		t.Fatal("tab debe pasar el foco a la lista de pasos")
	}
	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyDown})
	if m.cursor != 1 || m.viewIndex() != 1 {
		t.Fatalf("cursor=%d viewIndex=%d, quiere 1", m.cursor, m.viewIndex())
	}

	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.focusSteps || m.canceled || !m.formActive {
		t.Fatalf("esc debe volver al formulario sin cancelar: %+v", m)
	}
	if m.input.Value() != "valor" {
		t.Fatalf("valor perdido al volver: %q", m.input.Value())
	}

	m = pressForm(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if !m.focusSteps {
		t.Fatal("tab debe volver a enfocar pasos")
	}
	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if m.focusSteps {
		t.Fatal("tab debe devolver el foco al formulario")
	}
}

func TestCtrlArrowsFromForm(t *testing.T) {
	m := startFormModel(t, multiFormPlan(), t.TempDir())
	m.current = 2
	m.cursor = 2
	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyCtrlUp})
	if !m.focusSteps || m.cursor != 1 {
		t.Fatalf("ctrl+up: focusSteps=%v cursor=%d, quiere true/1", m.focusSteps, m.cursor)
	}
	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyCtrlDown})
	if m.cursor != 2 {
		t.Fatalf("ctrl+down: cursor=%d, quiere 2", m.cursor)
	}
}

func viewTestModel(t *testing.T, p plan, h int) stepsModel {
	t.Helper()
	m := newStepsModel(p, t.TempDir())
	m.width, m.height = 110, h
	m.stateDir = t.TempDir()
	out, _ := m.startForm(0)
	m = out.(stepsModel)
	return m
}

func TestViewFormInactiveSelect(t *testing.T) {
	p := plan{Title: "T", Steps: []planStep{{Title: "S", Cmd: "true", Inputs: []planInput{
		{Type: "input", Name: "name", Prompt: "Nombre"},
		{Type: "select", Name: "acc_count", Prompt: "Cuentas", Default: "0", Options: []string{"0", "1", "2", "3"}},
	}}}}
	m := viewTestModel(t, p, 24)
	m.formVals["acc_count"] = "0"

	plain := ansiRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(plain, "[x] 0") {
		t.Fatalf("select inactivo sin marca [x] 0:\n%s", plain)
	}
}

func TestViewFormScrollKeepsActiveField(t *testing.T) {
	inputs := []planInput{{Type: "input", Name: "name", Prompt: "Campo 1"}}
	for i := 2; i <= 14; i++ {
		inputs = append(inputs, planInput{Type: "input", Name: "f" + fmt.Sprint(i), Prompt: fmt.Sprintf("Campo %d", i)})
	}
	p := plan{Title: "T", Steps: []planStep{{Title: "S", Cmd: "true", Inputs: inputs}}}
	m := viewTestModel(t, p, 14)
	m.formIdx = len(inputs) - 1
	m.prepareField(inputs[m.formIdx])

	plain := ansiRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(plain, "Campo 14") {
		t.Fatalf("campo activo fuera de la ventana:\n%s", plain)
	}
}

func TestStepNavigationAfterFinish(t *testing.T) {
	p := plan{Title: "T", Steps: []planStep{
		{Title: "A", Cmd: "true"},
		{Title: "B", Cmd: "true"},
		{Title: "C", Cmd: "true"},
	}}
	m := newStepsModel(p, t.TempDir())
	m.finished = true
	m.cursor = 0
	m.current = 2 // el paso activo no debe anclar el detalle

	if m.showSteps {
		t.Fatal("al terminar debe mostrarse el reporte")
	}
	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if !m.showSteps {
		t.Fatal("tab debe mostrar la lista de pasos")
	}

	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyDown})
	if m.cursor != 1 || m.viewIndex() != 1 {
		t.Fatalf("cursor=%d viewIndex=%d, quiere 1", m.cursor, m.viewIndex())
	}

	m = pressModel(t, m, tea.KeyMsg{Type: tea.KeyTab})
	if m.showSteps {
		t.Fatal("tab debe volver al reporte")
	}
}
