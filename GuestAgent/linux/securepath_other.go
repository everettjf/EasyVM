//go:build !linux || !arm64

package main

import (
	"errors"
	"os"
	"path/filepath"
)

type portableUploadTarget struct {
	temporary   string
	destination string
}

func secureOpenGuestFile(path string) (*os.File, error) {
	if err := validateGuestPath(path, true); err != nil {
		return nil, err
	}
	return os.Open(path)
}

func secureCreateUpload(path string) (*os.File, secureUploadTarget, error) {
	if err := validateGuestPath(path, false); err != nil {
		return nil, nil, err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".ezvm-upload-*")
	if err != nil {
		return nil, nil, err
	}
	return file, &portableUploadTarget{temporary: file.Name(), destination: path}, nil
}

func (target *portableUploadTarget) commit(overwrite bool) error {
	if !overwrite {
		if _, err := os.Lstat(target.destination); err == nil {
			return errors.New("destination appeared during upload")
		}
	}
	if err := os.Rename(target.temporary, target.destination); err != nil {
		return err
	}
	target.temporary = ""
	return nil
}

func (target *portableUploadTarget) cleanup() {
	if target.temporary != "" {
		_ = os.Remove(target.temporary)
	}
}
