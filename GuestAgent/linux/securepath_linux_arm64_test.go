//go:build linux && arm64

package main

import (
	"errors"
	"syscall"
	"testing"
)

func TestCreateUploadEntryUsesOpenatWhenSupported(t *testing.T) {
	pathCalled := false
	fd, err := createUploadEntry(42, ".ezvm-upload-test",
		func(parentFD int, name string, flags int, mode uint32) (int, error) {
			if parentFD != 42 || name != ".ezvm-upload-test" || mode != 0600 {
				t.Fatalf("unexpected openat arguments: fd=%d name=%q mode=%o", parentFD, name, mode)
			}
			return 77, nil
		},
		func(string, int, uint32) (int, error) {
			pathCalled = true
			return -1, errors.New("unexpected fallback")
		},
	)
	if err != nil || fd != 77 || pathCalled {
		t.Fatalf("fd=%d err=%v pathCalled=%v", fd, err, pathCalled)
	}
}

func TestCreateUploadEntryFallsBackThroughBoundProcDescriptor(t *testing.T) {
	fd, err := createUploadEntry(42, ".ezvm-upload-test",
		func(int, string, int, uint32) (int, error) { return -1, syscall.EROFS },
		func(path string, flags int, mode uint32) (int, error) {
			if path != "/proc/self/fd/42/.ezvm-upload-test" {
				t.Fatalf("fallback path=%q", path)
			}
			if flags&syscall.O_EXCL == 0 || flags&oNoFollow == 0 || mode != 0600 {
				t.Fatalf("fallback did not preserve secure creation flags")
			}
			return 88, nil
		},
	)
	if err != nil || fd != 88 {
		t.Fatalf("fd=%d err=%v", fd, err)
	}
}

func TestCreateUploadEntryDoesNotFallbackForOrdinaryErrors(t *testing.T) {
	wanted := syscall.EACCES
	_, err := createUploadEntry(42, ".ezvm-upload-test",
		func(int, string, int, uint32) (int, error) { return -1, wanted },
		func(string, int, uint32) (int, error) {
			t.Fatal("unexpected fallback")
			return -1, nil
		},
	)
	if !errors.Is(err, wanted) {
		t.Fatalf("err=%v, want original access error", err)
	}
}

func TestCommitUploadEntryFallsBackToAtomicLinkWhenVirtioFSRejectsNoReplace(t *testing.T) {
	var linked, removedTemporary bool
	err := commitUploadEntry(
		12, "temporary", "destination", false,
		func(_ int, _, _ string, flags uintptr) syscall.Errno {
			if flags != renameNoReplace {
				t.Fatalf("rename flags=%d, want RENAME_NOREPLACE", flags)
			}
			return syscall.EROFS
		},
		func(_ int, oldName, newName string) syscall.Errno {
			linked = oldName == "temporary" && newName == "destination"
			return 0
		},
		func(_ int, name string) syscall.Errno {
			if name == "temporary" {
				removedTemporary = true
			}
			return 0
		},
	)
	if err != nil || !linked || !removedTemporary {
		t.Fatalf("err=%v linked=%v removedTemporary=%v", err, linked, removedTemporary)
	}
}

func TestCommitUploadEntryRollsBackLinkWhenTemporaryCannotBeRemoved(t *testing.T) {
	var removedDestination bool
	err := commitUploadEntry(
		12, "temporary", "destination", false,
		func(int, string, string, uintptr) syscall.Errno { return syscall.EOPNOTSUPP },
		func(int, string, string) syscall.Errno { return 0 },
		func(_ int, name string) syscall.Errno {
			if name == "temporary" {
				return syscall.EIO
			}
			removedDestination = name == "destination"
			return 0
		},
	)
	if err != syscall.EIO || !removedDestination {
		t.Fatalf("err=%v removedDestination=%v", err, removedDestination)
	}
}

func TestCommitUploadEntryDoesNotFallbackForOverwrite(t *testing.T) {
	usedFallback := false
	err := commitUploadEntry(
		12, "temporary", "destination", true,
		func(_ int, _, _ string, flags uintptr) syscall.Errno {
			if flags != 0 {
				t.Fatalf("overwrite rename flags=%d, want 0", flags)
			}
			return syscall.EROFS
		},
		func(int, string, string) syscall.Errno { usedFallback = true; return 0 },
		func(int, string) syscall.Errno { usedFallback = true; return 0 },
	)
	if err != syscall.EROFS || usedFallback {
		t.Fatalf("err=%v usedFallback=%v", err, usedFallback)
	}
}
