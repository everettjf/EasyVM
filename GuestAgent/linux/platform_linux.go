//go:build linux

package main

import (
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

type sockaddrVM struct {
	Family   uint16
	Reserved uint16
	Port     uint32
	CID      uint32
	Flags    uint8
	Zero     [3]uint8
}

func listenVSock(port uint32) (int, error) {
	fd, err := syscall.Socket(syscall.AF_VSOCK, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	address := sockaddrVM{Family: syscall.AF_VSOCK, Port: port, CID: vmaddrCIDAny}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&address)), unsafe.Sizeof(address))
	if errno != 0 {
		syscall.Close(fd)
		return -1, errno
	}
	if err := syscall.Listen(fd, 4); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	return fd, nil
}

func acceptSocket(fd int) (int, error) {
	for {
		connection, _, err := syscall.Accept(fd)
		if err == syscall.EINTR {
			continue
		}
		return connection, err
	}
}

func closeSocket(fd int) { _ = syscall.Close(fd) }

type fdStream struct{ fd int }

func (stream fdStream) Read(p []byte) (int, error)  { return syscall.Read(stream.fd, p) }
func (stream fdStream) Write(p []byte) (int, error) { return syscall.Write(stream.fd, p) }

func power(operation string) {
	time.Sleep(250 * time.Millisecond)
	argument := "poweroff"
	if operation == "restart" {
		argument = "reboot"
	}
	if err := exec.Command("systemctl", argument).Run(); err == nil {
		return
	}
	_ = exec.Command("/sbin/" + argument).Run()
}
