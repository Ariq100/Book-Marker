//go:build windows

package main

import (
	"os"
	"syscall"
	"unsafe"
)

// enableANSI turns on virtual-terminal processing so colors render in cmd.exe and PowerShell.
func enableANSI() bool {
	k := syscall.NewLazyDLL("kernel32.dll")
	getMode, setMode := k.NewProc("GetConsoleMode"), k.NewProc("SetConsoleMode")
	h := os.Stdout.Fd()
	var mode uint32
	if r, _, _ := getMode.Call(h, uintptr(unsafe.Pointer(&mode))); r == 0 {
		return false
	}
	const enableVirtualTerminalProcessing = 0x0004
	r, _, _ := setMode.Call(h, uintptr(mode|enableVirtualTerminalProcessing))
	return r != 0
}
