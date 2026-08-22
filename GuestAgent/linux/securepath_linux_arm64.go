//go:build linux && arm64

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

const (
	sysOpenat2          = 437
	sysRenameat2        = 276
	sysUnlinkat         = 35
	oPath               = 0x200000
	oNoFollow           = 0x20000
	resolveNoMagicLinks = 0x02
	resolveNoSymlinks   = 0x04
	resolveBeneath      = 0x08
	renameNoReplace     = 0x01
)

type openHow struct {
	Flags   uint64
	Mode    uint64
	Resolve uint64
}

type linuxUploadTarget struct {
	parentFD        int
	temporaryName   string
	destinationName string
}

func cString(value string) (*byte, error) {
	data := append([]byte(value), 0)
	if len(data) == 1 {
		return nil, errors.New("empty path")
	}
	return &data[0], nil
}

func openat2(dirfd int, path string, flags int, mode uint32) (int, error) {
	pointer, err := cString(path)
	if err != nil {
		return -1, err
	}
	how := openHow{Flags: uint64(flags), Mode: uint64(mode),
		Resolve: resolveBeneath | resolveNoMagicLinks | resolveNoSymlinks}
	fd, _, errno := syscall.RawSyscall6(sysOpenat2, uintptr(dirfd), uintptr(unsafe.Pointer(pointer)),
		uintptr(unsafe.Pointer(&how)), unsafe.Sizeof(how), 0, 0)
	if errno != 0 {
		return -1, errno
	}
	return int(fd), nil
}

func rootFD() (int, error) {
	root, err := syscall.Open("/", oPath|syscall.O_DIRECTORY|syscall.O_CLOEXEC, 0)
	return root, err
}

func secureOpenGuestFile(path string) (*os.File, error) {
	if err := validateGuestPath(path, true); err != nil {
		return nil, err
	}
	root, err := rootFD()
	if err != nil {
		return nil, err
	}
	defer syscall.Close(root)
	fd, err := openat2(root, path[1:], syscall.O_RDONLY|syscall.O_CLOEXEC|oNoFollow, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

func secureCreateUpload(path string) (*os.File, secureUploadTarget, error) {
	if err := validateGuestPath(path, false); err != nil {
		return nil, nil, err
	}
	root, err := rootFD()
	if err != nil {
		return nil, nil, err
	}
	defer syscall.Close(root)
	parentPath := filepath.Dir(path)[1:]
	if parentPath == "" {
		parentPath = "."
	}
	parentFD, err := openat2(root, parentPath, oPath|syscall.O_DIRECTORY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, nil, err
	}
	var random [16]byte
	if _, err = rand.Read(random[:]); err != nil {
		syscall.Close(parentFD)
		return nil, nil, err
	}
	temporaryName := ".easyvm-upload-" + hex.EncodeToString(random[:])
	fd, err := openat2(parentFD, temporaryName, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL|syscall.O_CLOEXEC|oNoFollow, 0600)
	if err != nil {
		syscall.Close(parentFD)
		return nil, nil, err
	}
	target := &linuxUploadTarget{parentFD: parentFD, temporaryName: temporaryName,
		destinationName: filepath.Base(path)}
	return os.NewFile(uintptr(fd), temporaryName), target, nil
}

func (target *linuxUploadTarget) commit(overwrite bool) error {
	oldName, _ := cString(target.temporaryName)
	newName, _ := cString(target.destinationName)
	flags := uintptr(0)
	if !overwrite {
		flags = renameNoReplace
	}
	_, _, errno := syscall.RawSyscall6(sysRenameat2, uintptr(target.parentFD), uintptr(unsafe.Pointer(oldName)),
		uintptr(target.parentFD), uintptr(unsafe.Pointer(newName)), flags, 0)
	if errno != 0 {
		return errno
	}
	target.temporaryName = ""
	syscall.Close(target.parentFD)
	target.parentFD = -1
	return nil
}

func (target *linuxUploadTarget) cleanup() {
	if target.parentFD < 0 {
		return
	}
	if target.temporaryName != "" {
		name, _ := cString(target.temporaryName)
		syscall.RawSyscall(sysUnlinkat, uintptr(target.parentFD), uintptr(unsafe.Pointer(name)), 0)
	}
	syscall.Close(target.parentFD)
	target.parentFD = -1
}
