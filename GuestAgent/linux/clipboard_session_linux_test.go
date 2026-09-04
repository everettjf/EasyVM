//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestReadClipboardPayloadRetainsAuthenticatedBytes(t *testing.T) {
	want := []byte("EZVM clipboard payload\nwith unicode: 你好")
	payload, byteCount, digest, err := readClipboardPayload(bytes.NewReader(want), maximumClipboardBytes)
	if err != nil {
		t.Fatal(err)
	}
	wantDigest := sha256.Sum256(want)
	if !bytes.Equal(payload, want) || byteCount != uint64(len(want)) ||
		digest != hex.EncodeToString(wantDigest[:]) {
		t.Fatalf("payload=%q byteCount=%d digest=%s", payload, byteCount, digest)
	}
}

func TestReadClipboardPayloadStopsOneBytePastLimit(t *testing.T) {
	reader := bytes.NewReader(make([]byte, 6))
	payload, byteCount, _, err := readClipboardPayload(reader, 4)
	if err != nil {
		t.Fatal(err)
	}
	if byteCount != 5 || len(payload) != 5 {
		t.Fatalf("payload bytes=%d count=%d", len(payload), byteCount)
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
