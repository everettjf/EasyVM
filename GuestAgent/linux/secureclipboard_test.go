package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSecureCreateClipboardOutputRejectsPathsOutsideExactSharedRoot(t *testing.T) {
	paths := []string{
		"/tmp/.ezvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt",
		clipboardSharedRoot + "/nested/.ezvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt",
		clipboardSharedRoot + "/ordinary.txt",
	}
	for _, path := range paths {
		if file, target, err := secureCreateClipboardOutput(path); err == nil {
			file.Close()
			target.cleanup()
			t.Fatalf("accepted unsafe clipboard output path %q", path)
		}
	}
}

func TestClipboardOutputTargetCleanupAndCommit(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "output")
	if err := os.WriteFile(path, []byte("payload"), 0600); err != nil {
		t.Fatal(err)
	}
	target := &clipboardOutputTarget{path: path}
	target.cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("uncommitted output still exists: %v", err)
	}
	if err := os.WriteFile(path, []byte("payload"), 0600); err != nil {
		t.Fatal(err)
	}
	target = &clipboardOutputTarget{path: path}
	if err := target.commit(false); err != nil {
		t.Fatal(err)
	}
	target.cleanup()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("committed output removed: %v", err)
	}
}
