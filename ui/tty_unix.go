//go:build !windows

package main

import "os"

// openConsoleInput abre la terminal real cuando stdin viene de un pipe
// (caso `curl | bash`).
func openConsoleInput() (*os.File, error) {
	return os.OpenFile("/dev/tty", os.O_RDWR, 0)
}

// enableVirtualTerminal no aplica fuera de Windows.
func enableVirtualTerminal(f *os.File) {}

// consoleAvailable indica si hay una terminal utilizable para interactuar.
func consoleAvailable() bool {
	f, err := openConsoleInput()
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}
