//go:build !windows

package main

import (
	"os"
	"os/exec"
)

// runPager muestra un archivo con el paginador externo de la plataforma.
// Devuelve false si no hay paginador disponible (el caller imprime directo).
func runPager(args []string) bool {
	if _, err := exec.LookPath("less"); err != nil {
		return false
	}
	c := exec.Command("less", append([]string{"-R"}, args...)...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run() == nil
}
