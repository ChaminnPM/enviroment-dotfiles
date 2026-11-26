//go:build windows

package main

import (
	"os"
	"os/exec"
)

// runPager usa el paginador disponible en Windows. `less` no existe ahi:
// primero `bat` (lo instala el paso de paquetes custom, respeta ANSI) y
// luego `more.com`, que viene con el SO. Si ninguno funciona, el caller
// imprime el archivo directo.
func runPager(args []string) bool {
	if _, err := exec.LookPath("bat"); err == nil {
		c := exec.Command("bat", append([]string{"--paging=always", "--style=plain", "--color=always"}, args...)...)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err == nil {
			return true
		}
	}
	if _, err := exec.LookPath("more.com"); err == nil {
		c := exec.Command("more.com", args...)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err == nil {
			return true
		}
	}
	return false
}
