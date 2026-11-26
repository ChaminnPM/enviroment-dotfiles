//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// openConsoleInput abre la consola real (CONIN$) cuando stdin viene de un
// pipe, que es el caso normal de `irm ... | iex`.
func openConsoleInput() (*os.File, error) {
	return os.OpenFile("CONIN$", os.O_RDWR, 0)
}

// enableVirtualTerminal activa ANSI/VT en conhost legacy. En Windows Terminal
// ya viene activo; sin esto la TUI pinta escapes como texto suelto.
func enableVirtualTerminal(f *os.File) {
	if f == nil {
		return
	}
	h := windows.Handle(f.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return // no es una consola (pipe o archivo)
	}
	// ENABLE_VIRTUAL_TERMINAL_PROCESSING
	_ = windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
}

// consoleAvailable indica si hay una consola real donde pedir datos.
func consoleAvailable() bool {
	f, err := openConsoleInput()
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}
