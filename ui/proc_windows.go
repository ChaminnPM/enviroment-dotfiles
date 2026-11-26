//go:build windows

package main

import (
	"os"
	"os/exec"
	"strconv"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows no entrega SIGTERM/SIGHUP; la cancelacion llega por
// Ctrl+C (os.Interrupt) o por cierre de consola.
var extraSignals = []os.Signal{}

// jobHandle es el Job Object compartido de nui. Con KILL_ON_JOB_CLOSE, si nui
// muere de golpe (crash, cierre de consola) Windows liquida el arbol de
// procesos del paso: no quedan winget/npm bloqueando el lock del instalador.
var (
	jobOnce   sync.Once
	jobHandle windows.Handle
	jobErr    error
)

func sharedJob() (windows.Handle, error) {
	jobOnce.Do(func() {
		h, err := windows.CreateJobObject(nil, nil)
		if err != nil {
			jobErr = err
			return
		}
		info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
		info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		if _, err := windows.SetInformationJobObject(h,
			windows.JobObjectExtendedLimitInformation,
			uintptr(unsafe.Pointer(&info)),
			uint32(unsafe.Sizeof(info))); err != nil {
			windows.CloseHandle(h)
			jobErr = err
			return
		}
		jobHandle = h
	})
	return jobHandle, jobErr
}

// setProcAttr pone el paso en su propio grupo de procesos para poder enviarle
// Ctrl+Break sin interrumpir al propio nui.
func setProcAttr(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
	}
}

// attachProc enlaza el recien iniciado al Job Object. Se llama justo despues
// de Start: hay una ventana de carrera minima, por eso killGroup ademas usa
// `taskkill /T` que recorre el arbol en el momento de matar.
func attachProc(c *exec.Cmd) {
	if c.Process == nil {
		return
	}
	job, err := sharedJob()
	if err != nil || job == 0 {
		return
	}
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE,
		false, uint32(c.Process.Pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(h)
	_ = windows.AssignProcessToJobObject(job, h)
}

// killGroup intenta un cierre ordenado (Ctrl+Break al grupo del paso) y, si
// sigue vivo, mata el arbol completo con taskkill.
func killGroup(c *exec.Cmd) {
	if c.Process == nil {
		return
	}
	pid := uint32(c.Process.Pid)
	// Ordenado: solo funciona si el hijo comparte la consola de nui.
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, pid)
	go escalateKill(c.Process.Pid)
}

// escalateKill espera un margen y luego mata el pid y TODA su descendencia.
func escalateKill(pid int) {
	time.Sleep(3 * time.Second)
	_ = exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(pid)).Run()
}
