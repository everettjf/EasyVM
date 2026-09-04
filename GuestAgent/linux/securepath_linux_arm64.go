//go:build linux && arm64

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

const (
	sysOpenat2          = 437
	sysRenameat2        = 276
	sysLinkat           = 37
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
	temporaryName := ".ezvm-upload-" + hex.EncodeToString(random[:])
	// The parent was resolved with openat2 beneath / and the random basename
	// contains no separators. Use openat for creation because virtiofs can
	// reject openat2(O_CREAT) despite permitting ordinary writes.
	fd, err := createUploadEntry(parentFD, temporaryName, syscall.Openat, syscall.Open)
	if err != nil {
		syscall.Close(parentFD)
		return nil, nil, err
	}
	target := &linuxUploadTarget{parentFD: parentFD, temporaryName: temporaryName,
		destinationName: filepath.Base(path)}
	return os.NewFile(uintptr(fd), temporaryName), target, nil
}

type openUploadAtOperation func(int, string, int, uint32) (int, error)
type openUploadPathOperation func(string, int, uint32) (int, error)

func createUploadEntry(
	parentFD int,
	temporaryName string,
	openAt openUploadAtOperation,
	openPath openUploadPathOperation,
) (int, error) {
	flags := syscall.O_WRONLY | syscall.O_CREAT | syscall.O_EXCL | syscall.O_CLOEXEC | oNoFollow
	fd, err := openAt(parentFD, temporaryName, flags, 0600)
	if err == nil {
		return fd, nil
	}
	if !errors.Is(err, syscall.EROFS) && !errors.Is(err, syscall.EINVAL) &&
		!errors.Is(err, syscall.ENOSYS) && !errors.Is(err, syscall.EOPNOTSUPP) {
		return -1, err
	}
	// macOS Virtualization.framework's virtiofs implementation can reject an
	// otherwise valid O_CREAT operation addressed through openat(2). Resolve
	// through the already-open directory descriptor instead. /proc/self/fd/N
	// remains bound to that descriptor even if an untrusted shared-directory
	// entry is concurrently renamed, while O_EXCL and O_NOFOLLOW continue to
	// protect the random final component.
	path := fmt.Sprintf("/proc/self/fd/%d/%s", parentFD, temporaryName)
	return openPath(path, flags, 0600)
}

func (target *linuxUploadTarget) commit(overwrite bool) error {
	err := commitUploadEntry(
		target.parentFD, target.temporaryName, target.destinationName, overwrite,
		renameUploadEntry, linkUploadEntry, unlinkUploadEntry,
	)
	if err != nil {
		return err
	}
	target.temporaryName = ""
	syscall.Close(target.parentFD)
	target.parentFD = -1
	return nil
}

type renameUploadOperation func(int, string, string, uintptr) syscall.Errno
type linkUploadOperation func(int, string, string) syscall.Errno
type unlinkUploadOperation func(int, string) syscall.Errno

func renameUploadEntry(parentFD int, oldName, newName string, flags uintptr) syscall.Errno {
	oldPointer, _ := cString(oldName)
	newPointer, _ := cString(newName)
	_, _, errno := syscall.RawSyscall6(sysRenameat2, uintptr(parentFD), uintptr(unsafe.Pointer(oldPointer)),
		uintptr(parentFD), uintptr(unsafe.Pointer(newPointer)), flags, 0)
	return errno
}

func linkUploadEntry(parentFD int, oldName, newName string) syscall.Errno {
	oldPointer, _ := cString(oldName)
	newPointer, _ := cString(newName)
	_, _, errno := syscall.RawSyscall6(sysLinkat,
		uintptr(parentFD), uintptr(unsafe.Pointer(oldPointer)),
		uintptr(parentFD), uintptr(unsafe.Pointer(newPointer)), 0, 0)
	return errno
}

func unlinkUploadEntry(parentFD int, name string) syscall.Errno {
	pointer, _ := cString(name)
	_, _, errno := syscall.RawSyscall(sysUnlinkat,
		uintptr(parentFD), uintptr(unsafe.Pointer(pointer)), 0)
	return errno
}

func commitUploadEntry(
	parentFD int,
	temporaryName, destinationName string,
	overwrite bool,
	rename renameUploadOperation,
	link linkUploadOperation,
	unlink unlinkUploadOperation,
) error {
	flags := uintptr(0)
	if !overwrite {
		flags = renameNoReplace
	}
	errno := rename(parentFD, temporaryName, destinationName, flags)
	// virtiofs currently rejects RENAME_NOREPLACE with EROFS even while the
	// shared directory itself is writable. linkat provides the same atomic
	// no-replace guarantee on one directory, so use it only for filesystems
	// that cannot implement the rename flag. The random temporary name remains
	// addressed through the already verified parent descriptor.
	if !overwrite && (errno == syscall.EROFS || errno == syscall.EINVAL ||
		errno == syscall.ENOSYS || errno == syscall.EOPNOTSUPP) {
		linkErrno := link(parentFD, temporaryName, destinationName)
		if linkErrno != 0 {
			return linkErrno
		}
		unlinkErrno := unlink(parentFD, temporaryName)
		if unlinkErrno != 0 {
			// Roll back the destination if the temporary link could not be
			// removed; callers must never observe a failed partial commit.
			_ = unlink(parentFD, destinationName)
			return unlinkErrno
		}
		errno = 0
	}
	if errno != 0 {
		return errno
	}
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
