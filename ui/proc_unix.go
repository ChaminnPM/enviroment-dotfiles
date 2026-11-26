//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

// extraSignals son las senales externas que cancelan el plan ademas de Ctrl+C.
var extraSignals = []os.Signal{syscall.SIGTERM, syscall.SIGHUP}

// setProcAttr aísla el paso en su propio grupo de procesos para poder
// cancelarlo sin tocar al propio nui.
func setProcAttr(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// attachProc enlaza el proceso recien iniciado. En POSIX no hay nada que
// enlazar: el grupo de procesos ya se creo con Setpgid.
func attachProc(c *exec.Cmd) {}

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
