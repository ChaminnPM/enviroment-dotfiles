//go:build !windows

package main

import "path/filepath"

// platformLogSubdir es la ruta relativa al home donde nui guarda logs.
func platformLogSubdir() string {
	return filepath.Join(".local", "state", "enviroment-dotfiles", "logs")
}
