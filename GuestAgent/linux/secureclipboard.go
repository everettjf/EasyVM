package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Linux O_NOFOLLOW. The Guest Agent production target is Linux/aarch64; this
// local value also keeps host-side contract tests independent of x/sys.
const oNoFollowPortable = 0x20000

// clipboardOutputTarget writes directly to the final, unguessable staging
// filename. The Host never reads it until clipboardGet has returned success,
// so a second rename is unnecessary. This is also the only creation form that
// Virtualization.framework's virtiofs currently accepts reliably: mutations
// addressed through an open directory descriptor can incorrectly return EROFS.
type clipboardOutputTarget struct {
	path      string
	committed bool
}

func secureCreateClipboardOutput(path string) (*os.File, secureUploadTarget, error) {
	// validateClipboardRequest already produces this shape, but keep the
	// filesystem boundary self-validating so a future caller cannot turn the
	// compatibility path into a general arbitrary-file primitive.
	if filepath.Dir(path) != clipboardSharedRoot || !clipboardItemPattern.MatchString(filepath.Base(path)) {
		return nil, nil, errors.New("invalid clipboard output path")
	}
	flags := syscall.O_WRONLY | syscall.O_CREAT | syscall.O_EXCL | syscall.O_CLOEXEC | oNoFollowPortable
	fd, err := syscall.Open(path, flags, 0600)
	if err != nil {
		return nil, nil, fmt.Errorf("create clipboard output %q: %w", path, err)
	}
	return os.NewFile(uintptr(fd), path), &clipboardOutputTarget{path: path}, nil
}

func (target *clipboardOutputTarget) commit(overwrite bool) error {
	if overwrite {
		return errors.New("clipboard output cannot overwrite an existing file")
	}
	target.committed = true
	return nil
}

func (target *clipboardOutputTarget) cleanup() {
	if !target.committed && target.path != "" {
		_ = os.Remove(target.path)
	}
}
