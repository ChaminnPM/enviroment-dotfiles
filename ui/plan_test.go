package main

import (
	"bufio"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writePlan(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "plan.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestLoadPlanShell verifica el contrato multiplataforma del plan:
// shell por defecto bash, pwsh normalizado y rechazo de shells desconocidas.
func TestLoadPlanShell(t *testing.T) {
	dir := t.TempDir()

	cases := []struct {
		name   string
		json   string
		shell  string
		isPwsh bool
		ext    string
	}{
		{"sin shell", `{"steps":[{"title":"A","cmd":"true"}]}`, "bash", false, "env"},
		{"bash explicito", `{"shell":"bash","steps":[{"cmd":"true"}]}`, "bash", false, "env"},
		{"pwsh", `{"shell":"pwsh","steps":[{"cmd":"true"}]}`, "pwsh", true, "ps1"},
		{"powershell normalizado", `{"shell":"PowerShell","steps":[{"cmd":"true"}]}`, "pwsh", true, "ps1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, err := loadPlan(writePlan(t, dir, tc.json))
			if err != nil {
				t.Fatalf("plan rechazado: %v", err)
			}
			if p.Shell != tc.shell {
				t.Fatalf("shell = %q, queria %q", p.Shell, tc.shell)
			}
			if got := p.isPwsh(); got != tc.isPwsh {
				t.Fatalf("isPwsh = %v, queria %v", got, tc.isPwsh)
			}
			if got := p.resultExt(); got != tc.ext {
				t.Fatalf("resultExt = %q, queria %q", got, tc.ext)
			}
		})
	}

	for _, bad := range []string{
		`{"shell":"fish","steps":[{"cmd":"true"}]}`,
		`{"steps":[{"title":"sin comando"}]}`,
		`{"steps":[{"cmd":"", "argv":[]}]}`,
	} {
		if _, err := loadPlan(writePlan(t, dir, bad)); err == nil {
			t.Fatalf("plan invalido aceptado: %s", bad)
		}
	}
}

// TestLoadPlanArgv: argv es la forma preferida y puede existir sin cmd.
func TestLoadPlanArgv(t *testing.T) {
	dir := t.TempDir()
	p, err := loadPlan(writePlan(t, dir,
		`{"shell":"pwsh","steps":[{"title":"S","argv":["pwsh","-File","C:\\tmp\\step-01.ps1"]}]}`))
	if err != nil {
		t.Fatalf("plan con argv rechazado: %v", err)
	}
	want := []string{"pwsh", "-File", `C:\tmp\step-01.ps1`}
	if got := p.Steps[0].Argv; !reflect.DeepEqual(got, want) {
		t.Fatalf("argv = %q, queria %q", got, want)
	}
}

// TestStepCommand comprueba como se materializa cada forma del plan.
func TestStepCommand(t *testing.T) {
	sameName := func(got, want string) bool {
		base := strings.ToLower(filepath.Base(got))
		return base == strings.ToLower(want) || strings.TrimSuffix(base, ".exe") == strings.ToLower(want)
	}

	t.Run("argv gana sobre cmd", func(t *testing.T) {
		c := stepCommand(planStep{
			Cmd:  "Write-Host hola",
			Argv: []string{"pwsh", "-File", `C:\Users\John Doe\step-01.ps1`},
		}, "pwsh")
		if !sameName(c.Path, "pwsh") {
			t.Fatalf("Path = %q", c.Path)
		}
		want := []string{"pwsh", "-File", `C:\Users\John Doe\step-01.ps1`}
		if !reflect.DeepEqual(c.Args, want) {
			t.Fatalf("Args = %q, queria %q", c.Args, want)
		}
	})

	t.Run("fallback bash", func(t *testing.T) {
		c := stepCommand(planStep{Cmd: "echo hi"}, "bash")
		if !sameName(c.Path, "bash") ||
			!reflect.DeepEqual(c.Args, []string{"bash", "-c", "echo hi"}) {
			t.Fatalf("cmd = %q %+v", c.Path, c.Args)
		}
	})

	t.Run("fallback pwsh", func(t *testing.T) {
		c := stepCommand(planStep{Cmd: "Get-Date"}, "pwsh")
		if !sameName(c.Path, "pwsh") {
			t.Fatalf("Path = %q", c.Path)
		}
		want := []string{"pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "Get-Date"}
		if !reflect.DeepEqual(c.Args, want) {
			t.Fatalf("Args = %q, queria %q", c.Args, want)
		}
	})
}

// TestResultLine fija el formato de los valores de formulario por shell.
func TestResultLine(t *testing.T) {
	cases := []struct {
		ext, name, value, want string
	}{
		{"env", "p_name", "Chaminn", "p_name='Chaminn'"},
		{"env", "p_name", "O'Brien", `p_name='O'\''Brien'`},
		{"env", "extras", "bat\neza", "extras='bat\neza'"},
		{"ps1", "p_name", "Chaminn", "$p_name = 'Chaminn'"},
		{"ps1", "p_name", "O'Brien", "$p_name = 'O''Brien'"},
		{"ps1", "extras", "bat\neza", "$extras = 'bat\neza'"},
		{"ps1", "p_email", "", "$p_email = ''"},
	}
	for _, tc := range cases {
		if got := resultLine(tc.name, tc.value, tc.ext); got != tc.want {
			t.Fatalf("resultLine(%q,%q,%q) = %q, queria %q", tc.ext, tc.name, tc.value, got, tc.want)
		}
	}
}

// TestResultPath: la extension cambia pero el numero de paso manda.
func TestResultPath(t *testing.T) {
	bash := resultPath("/state", 3, "env")
	ps := resultPath("/state", 12, "ps1")
	if filepath.Base(bash) != "result-03.env" {
		t.Fatalf("bash = %q", bash)
	}
	if filepath.Base(ps) != "result-12.ps1" {
		t.Fatalf("ps = %q", ps)
	}
}

// TestPromptInputsNonInteractive: con NUI_NONINTERACTIVE=1 no se puede leer
// stdin (en `curl | bash` esta a EOF) ni preguntar: se escriben los defaults.
func TestPromptInputsNonInteractive(t *testing.T) {
	t.Setenv("NUI_NONINTERACTIVE", "1")
	dir := t.TempDir()
	inputs := []planInput{
		{Type: "input", Name: "p_name", Prompt: "Nombre", Default: "Chaminn"},
		{Type: "select", Name: "extras", Prompt: "Paquetes", Multi: true,
			Options: []string{"bat", "eza"}, Default: "bat eza"},
		{Type: "confirm", Name: "enviar", Prompt: "Enviar", Default: "false"},
		{Type: "input", Name: "oculto", Prompt: "Oculto", ShowIf: []inputCondition{
			{Field: "p_name", Op: "eq", Value: "nada"},
		}},
	}
	// bufio.Reader sobre una cadena vacia: cualquier lectura real daria EOF.
	promptInputs(dir, 0, inputs, newReader(""), "ps1", true)

	raw, err := os.ReadFile(resultPath(dir, 1, "ps1"))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"$p_name = 'Chaminn'",
		"$extras = 'bat\neza'",
		"$enviar = 'false'",
		"$oculto = ''",
		"",
	}, "\n")
	if string(raw) != want {
		t.Fatalf("resultados =\n%q\nqueria\n%q", string(raw), want)
	}
}

// TestPromptInputsInteractivo: con entrada disponible se usan los valores
// tecleados, no los defaults.
func TestPromptInputsInteractivo(t *testing.T) {
	t.Setenv("NUI_NONINTERACTIVE", "0")
	dir := t.TempDir()
	inputs := []planInput{
		{Type: "select", Name: "extras", Prompt: "Paquetes", Multi: true,
			Options: []string{"bat", "eza"}, Default: "bat"},
	}
	promptInputs(dir, 0, inputs, newReader("2\n"), "ps1", false)
	raw, _ := os.ReadFile(resultPath(dir, 1, "ps1"))
	if !strings.Contains(string(raw), "$extras = 'eza'") {
		t.Fatalf("no se aplico la seleccion: %q", string(raw))
	}
}

func newReader(s string) *bufio.Reader { return bufio.NewReader(strings.NewReader(s)) }
