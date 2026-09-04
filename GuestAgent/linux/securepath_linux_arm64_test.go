//go:build linux && arm64

package main

import (
	"syscall"
	"testing"
)

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
