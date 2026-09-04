//go:build linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

type clipboardSessionRequest struct {
	Operation string `json:"operation"`
	clipboardRequest
}

var clipboardOwner = struct {
	sync.Mutex
	command *exec.Cmd
	done    chan struct{}
}{}

var clipboardPublication sync.Mutex

const (
	sessionClipboardCopyExecutable  = "/usr/bin/wl-copy"
	sessionClipboardPasteExecutable = "/usr/bin/wl-paste"
)

func startClipboardSessionServer(uid uint32) (*net.UnixListener, string, error) {
	runtimeDirectory := os.Getenv("XDG_RUNTIME_DIR")
	expected := filepath.Join("/run/user", strconv.FormatUint(uint64(uid), 10))
	if runtimeDirectory != expected {
		return nil, "", errors.New("invalid XDG_RUNTIME_DIR for session clipboard")
	}
	socketPath := desktopSessionSocketPath(uid)
	_ = os.Remove(socketPath)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		return nil, "", err
	}
	if err := os.Chmod(socketPath, 0600); err != nil {
		listener.Close()
		return nil, "", err
	}
	go func() {
		for {
			connection, err := listener.AcceptUnix()
			if err != nil {
				return
			}
			go serveClipboardSession(connection)
		}
	}()
	return listener, socketPath, nil
}

func serveClipboardSession(connection *net.UnixConn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(15 * time.Second))
	data, err := bufio.NewReader(io.LimitReader(connection, 8193)).ReadBytes('\n')
	if err != nil || len(data) > 8192 {
		return
	}
	var request clipboardSessionRequest
	if json.Unmarshal(data, &request) != nil {
		return
	}
	if request.Operation == "desktopNotifications" {
		encoded, _ := json.Marshal(notificationSessionResponse())
		_, _ = connection.Write(append(encoded, '\n'))
		return
	}
	result := executeClipboardSessionRequest(request)
	encoded, _ := json.Marshal(result)
	_, _ = connection.Write(append(encoded, '\n'))
}

func executeClipboardSessionRequest(request clipboardSessionRequest) clipboardResult {
	path, err := validateClipboardRequest(request.clipboardRequest)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	switch request.Operation {
	case "clipboardSet":
		return setSessionClipboard(path, request.clipboardRequest)
	case "clipboardGet":
		return getSessionClipboard(path, request.clipboardRequest)
	default:
		return clipboardResult{Message: "unsupported session clipboard operation"}
	}
}

func setSessionClipboard(path string, request clipboardRequest) clipboardResult {
	// Re-open beneath / with openat2(RESOLVE_NO_SYMLINKS) on the production
	// architecture. Lexical validation alone is not enough because the shared
	// staging directory is writable by the desktop user.
	file, err := secureOpenGuestFile(path)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || uint64(info.Size()) > maximumClipboardBytes {
		file.Close()
		return clipboardResult{Message: "clipboard staging input is invalid"}
	}
	payload, byteCount, digestText, err := readClipboardPayload(file, maximumClipboardBytes)
	closeError := file.Close()
	if err != nil || closeError != nil || byteCount != request.ByteCount || byteCount > maximumClipboardBytes {
		return clipboardResult{Message: "clipboard staging size mismatch"}
	}
	if request.SHA256 != digestText {
		return clipboardResult{Message: "clipboard staging digest mismatch"}
	}
	// Replacing a Wayland data-control source is ordered. Wait for the old
	// wl-copy process to finish its compositor teardown before registering the
	// next source; otherwise the late teardown can clear a selection which the
	// new owner has already published and verified.
	clipboardPublication.Lock()
	defer clipboardPublication.Unlock()
	stopSessionClipboardOwner()
	command, err := startVerifiedClipboardOwner(
		payload,
		request.MIMEType,
		func(payload []byte, mimeType string) *exec.Cmd {
			command := exec.Command(sessionClipboardCopyExecutable, clipboardCopyArguments(mimeType)...)
			// An io.Reader makes os/exec feed the distribution-matched wl-copy
			// through an OS pipe. A regular-file stdin can fail with EPIPE in the
			// Omarchy data-control session, while mixing the separately built Rust
			// owner with the distribution wl-paste delays cross-client retrieval.
			command.Stdin = bytes.NewReader(payload)
			command.Stderr = os.Stderr
			return command
		},
		readSessionClipboardPayload,
		time.Sleep,
	)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	done := make(chan struct{})
	clipboardOwner.Lock()
	clipboardOwner.command = command
	clipboardOwner.done = done
	clipboardOwner.Unlock()
	go func() {
		_ = command.Wait()
		close(done)
		clipboardOwner.Lock()
		if clipboardOwner.command == command {
			clipboardOwner.command = nil
			clipboardOwner.done = nil
		}
		clipboardOwner.Unlock()
	}()
	return clipboardResult{Success: true, Message: "Guest clipboard updated.", ByteCount: byteCount, SHA256: digestText}
}

func clipboardCopyArguments(mimeType string) []string {
	arguments := []string{"--foreground"}
	if mimeType != clipboardTextMIME {
		arguments = append(arguments, "--type", mimeType)
	}
	return arguments
}

func stopSessionClipboardOwner() {
	clipboardOwner.Lock()
	command := clipboardOwner.command
	done := clipboardOwner.done
	clipboardOwner.command = nil
	clipboardOwner.done = nil
	clipboardOwner.Unlock()
	if command == nil {
		return
	}
	if command.Process != nil {
		_ = command.Process.Kill()
	}
	if done != nil {
		<-done
	}
}

const clipboardPublicationAttempts = 5
const clipboardPublicationVerifications = 3

func startVerifiedClipboardOwner(
	payload []byte,
	mimeType string,
	makeCommand func([]byte, string) *exec.Cmd,
	readBack func(string) ([]byte, error),
	pause func(time.Duration),
) (*exec.Cmd, error) {
	var lastError error
	for attempt := 0; attempt < clipboardPublicationAttempts; attempt++ {
		command := makeCommand(payload, mimeType)
		if err := command.Start(); err != nil {
			lastError = err
		} else {
			// A freshly activated Hyprland data-control session can reject its
			// first ownership request. Prove the exact bytes are serveable before
			// acknowledging the authenticated Host request; a longer wait on the
			// same rejected owner does not recover it.
			verified := true
			for verification := 0; verification < clipboardPublicationVerifications; verification++ {
				pause(time.Duration(attempt+1) * 100 * time.Millisecond)
				actual, err := readBack(mimeType)
				if err != nil {
					lastError = err
					verified = false
					break
				}
				if !bytes.Equal(actual, payload) {
					lastError = errors.New("Wayland clipboard readback did not match")
					verified = false
					break
				}
			}
			if verified {
				return command, nil
			}
			if command.Process != nil {
				_ = command.Process.Kill()
			}
			_ = command.Wait()
		}
		if attempt+1 < clipboardPublicationAttempts {
			pause(time.Duration(attempt+1) * 100 * time.Millisecond)
		}
	}
	return nil, fmt.Errorf("could not publish verified Wayland clipboard: %w", lastError)
}

func readSessionClipboardPayload(mimeType string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	arguments := []string{"--type", mimeType}
	if mimeType == clipboardTextMIME {
		arguments = append(arguments, "--no-newline")
	}
	command := exec.CommandContext(ctx, sessionClipboardPasteExecutable, arguments...)
	var output bytes.Buffer
	writer := &clipboardCountingWriter{writer: &output, limit: maximumClipboardBytes}
	command.Stdout = writer
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return nil, err
	}
	if writer.byteCount > maximumClipboardBytes {
		return nil, errors.New("clipboard readback exceeds limit")
	}
	return output.Bytes(), nil
}

func readClipboardPayload(reader io.Reader, limit uint64) ([]byte, uint64, string, error) {
	payload, err := io.ReadAll(io.LimitReader(reader, int64(limit+1)))
	byteCount := uint64(len(payload))
	digest := sha256.Sum256(payload)
	return payload, byteCount, hex.EncodeToString(digest[:]), err
}

func getSessionClipboard(path string, request clipboardRequest) clipboardResult {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	// Create an unguessable file and retain an open descriptor for the parent.
	// Committing through secureUploadTarget prevents symlink traversal and
	// refuses to replace a destination that appeared during capture.
	file, target, err := secureCreateUpload(path)
	if err != nil {
		return clipboardResult{Message: "could not create clipboard staging output: " + err.Error()}
	}
	committed := false
	defer func() {
		if !committed {
			target.cleanup()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	arguments := []string{"--type", request.MIMEType}
	if request.MIMEType == clipboardTextMIME {
		arguments = append(arguments, "--no-newline")
	}
	command := exec.CommandContext(ctx, sessionClipboardPasteExecutable, arguments...)
	hasher := sha256.New()
	counter := &clipboardCountingWriter{
		writer: io.MultiWriter(file, hasher),
		limit:  maximumClipboardBytes,
	}
	command.Stdout = counter
	command.Stderr = io.Discard
	err = command.Run()
	closeError := file.Close()
	if counter.byteCount > maximumClipboardBytes {
		return clipboardResult{Message: "clipboard output is invalid"}
	}
	if err != nil || closeError != nil {
		return clipboardResult{Message: "could not read the Wayland clipboard"}
	}
	if err := target.commit(false); err != nil {
		return clipboardResult{Message: "could not commit clipboard staging output: " + err.Error()}
	}
	committed = true
	return clipboardResult{
		Success: true, Message: "Guest clipboard captured.",
		ByteCount: counter.byteCount, SHA256: hex.EncodeToString(hasher.Sum(nil)),
	}
}

type clipboardCountingWriter struct {
	writer    io.Writer
	byteCount uint64
	limit     uint64
}

func (writer *clipboardCountingWriter) Write(data []byte) (int, error) {
	if writer.byteCount >= writer.limit+1 {
		return 0, errors.New("clipboard output exceeds limit")
	}
	remaining := writer.limit + 1 - writer.byteCount
	if uint64(len(data)) > remaining {
		data = data[:remaining]
	}
	written, err := writer.writer.Write(data)
	writer.byteCount += uint64(written)
	if err == nil && writer.byteCount > writer.limit {
		err = errors.New("clipboard output exceeds limit")
	}
	return written, err
}

func proxyClipboardRequest(operation string, payload []byte) clipboardResult {
	var request clipboardRequest
	if err := json.Unmarshal(payload, &request); err != nil {
		return clipboardResult{Message: "invalid clipboard request"}
	}
	required := "clipboard-agent-text-v1"
	if request.MIMEType == clipboardImageMIME {
		required = "clipboard-agent-image-v1"
	}
	if _, err := validateClipboardRequest(request); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	session, ok := activeDesktopSession(time.Now(), required)
	if !ok {
		return clipboardResult{Message: "no clipboard-capable desktop session is active"}
	}
	if err := validateDesktopSessionSocket(session); err != nil {
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	rawConnection, err := net.DialTimeout("unix", session.socketPath, 2*time.Second)
	if err != nil {
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	connection, ok := rawConnection.(*net.UnixConn)
	if !ok {
		rawConnection.Close()
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	defer connection.Close()
	peerUID, err := unixPeerUID(connection)
	if err != nil || peerUID != session.uid {
		return clipboardResult{Message: "desktop clipboard session identity mismatch"}
	}
	_ = connection.SetDeadline(time.Now().Add(15 * time.Second))
	encoded, _ := json.Marshal(clipboardSessionRequest{Operation: operation, clipboardRequest: request})
	if _, err := connection.Write(append(encoded, '\n')); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	data, err := bufio.NewReader(io.LimitReader(connection, 8193)).ReadBytes('\n')
	if err != nil || len(data) > 8192 {
		return clipboardResult{Message: "invalid desktop clipboard response"}
	}
	var result clipboardResult
	if json.Unmarshal(data, &result) != nil {
		return clipboardResult{Message: "invalid desktop clipboard response"}
	}
	return result
}

func validateDesktopSessionSocket(session registeredSession) error {
	info, err := os.Lstat(session.socketPath)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return errors.New("desktop session socket is missing")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != session.uid {
		return errors.New("desktop session socket owner mismatch")
	}
	return nil
}
