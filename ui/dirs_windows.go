//go:build windows

package main

import "path/filepath"

// platformLogSubdir: en Windows todo el estado del proyecto vive bajo
// ~/.config/enviroment-dotfiles (misma raiz que la config de OpenCode), para
// que backup, logs y config sean un unico arbol que se pueda borrar entero.
func platformLogSubdir() string {
	return filepath.Join(".config", "enviroment-dotfiles", "logs")
}
