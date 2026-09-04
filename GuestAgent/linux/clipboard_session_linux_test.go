//go:build linux

package main

import (
	"bytes"
	"testing"
)

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
