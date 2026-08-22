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
		// syscall.Accept asks the Go syscall package to decode the peer
		// sockaddr. Its legacy Linux decoder does not understand AF_VSOCK and
		// returns EAFNOSUPPORT after the kernel has accepted the connection.
		// The agent does not use the peer address, so omit it at the syscall
		// boundary and retain close-on-exec atomically.
		connection, _, errno := syscall.Syscall6(
			syscall.SYS_ACCEPT4, uintptr(fd), 0, 0, syscall.SOCK_CLOEXEC, 0, 0,
		)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return -1, errno
		}
		return int(connection), nil
	}
}

func closeSocket(fd int) { _ = syscall.Close(fd) }

type fdStream struct{ fd int }

func (stream fdStream) Read(p []byte) (int, error) { return syscall.Read(stream.fd, p) }
func (stream fdStream) Write(p []byte) (int, error) {
	written := 0
	for written < len(p) {
		count, err := syscall.Write(stream.fd, p[written:])
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return written, err
		}
		if count == 0 {
			return written, syscall.EIO
		}
		written += count
	}
	return written, nil
}

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
