//go:build linux

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os/exec"
	"testing"
	"time"
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

func TestSessionClipboardUsesDistributionMatchedCopyFrontend(t *testing.T) {
	if sessionClipboardCopyExecutable != "/usr/bin/wl-copy" {
		t.Fatalf("copy executable=%q, want the distribution-matched frontend", sessionClipboardCopyExecutable)
	}
	if sessionClipboardPasteExecutable != "/usr/bin/wl-paste" {
		t.Fatalf("paste executable=%q, want the distribution-matched frontend", sessionClipboardPasteExecutable)
	}
}

func TestStartVerifiedClipboardOwnerRetriesRejectedPublications(t *testing.T) {
	want := []byte("clipboard bytes")
	starts := 0
	reads := 0
	command, err := startVerifiedClipboardOwner(
		want,
		clipboardTextMIME,
		func(_ []byte, _ string) *exec.Cmd {
			starts++
			return exec.Command("sleep", "30")
		},
		func(_ string) ([]byte, error) {
			reads++
			if reads < 3 {
				return nil, errors.New("selection rejected")
			}
			return append([]byte(nil), want...), nil
		},
		func(time.Duration) {},
	)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	}()
	if starts != 3 || reads != 3+clipboardPublicationVerifications-1 {
		t.Fatalf("starts=%d reads=%d, want retries followed by stable verification", starts, reads)
	}
}

func TestStartVerifiedClipboardOwnerRejectsPersistentMismatch(t *testing.T) {
	starts := 0
	command, err := startVerifiedClipboardOwner(
		[]byte("expected"),
		clipboardTextMIME,
		func(_ []byte, _ string) *exec.Cmd {
			starts++
			return exec.Command("sleep", "30")
		},
		func(_ string) ([]byte, error) { return []byte("wrong"), nil },
		func(time.Duration) {},
	)
	if err == nil || command != nil {
		t.Fatalf("command=%v error=%v, want verified publication failure", command, err)
	}
	if starts != clipboardPublicationAttempts {
		t.Fatalf("starts=%d, want %d", starts, clipboardPublicationAttempts)
	}
}

func TestStopSessionClipboardOwnerWaitsForProcessExit(t *testing.T) {
	command := exec.Command("sleep", "30")
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	clipboardOwner.Lock()
	clipboardOwner.command = command
	clipboardOwner.done = done
	clipboardOwner.Unlock()
	go func() {
		_ = command.Wait()
		close(done)
	}()

	stopSessionClipboardOwner()
	select {
	case <-done:
	default:
		t.Fatal("clipboard owner stop returned before process exit")
	}
	if command.ProcessState == nil {
		t.Fatal("clipboard owner process was not reaped")
	}
	clipboardOwner.Lock()
	defer clipboardOwner.Unlock()
	if clipboardOwner.command != nil || clipboardOwner.done != nil {
		t.Fatal("stopped clipboard owner remained registered")
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
