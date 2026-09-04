//go:build linux

package main

import (
	"bytes"
	"io"
	"os"
	"testing"
)

func TestClipboardInputReaderStartsAtBeginningAfterDigestRead(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "clipboard-input-*")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	payload := []byte("EZVM clipboard payload\nwith unicode: 你好")
	if _, err := file.Write(payload); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(io.Discard, file); err != nil {
		t.Fatal(err)
	}

	actual, err := io.ReadAll(clipboardInputReader(file, int64(len(payload))))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, payload) {
		t.Fatalf("clipboard input = %q, want %q", actual, payload)
	}
}

func TestClipboardCountingWriterStopsOneBytePastLimit(t *testing.T) {
	var output bytes.Buffer
	writer := &clipboardCountingWriter{writer: &output, limit: 4}

	written, err := writer.Write([]byte("abcdef"))
	if err == nil {
		t.Fatal("oversized write unexpectedly succeeded")
	}
	if written != 5 || writer.byteCount != 5 || output.String() != "abcde" {
		t.Fatalf("written=%d count=%d output=%q", written, writer.byteCount, output.String())
	}
	if written, err = writer.Write([]byte("z")); err == nil || written != 0 {
		t.Fatalf("second write = (%d, %v), want (0, error)", written, err)
	}
}
