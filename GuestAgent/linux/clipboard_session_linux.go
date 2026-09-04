//go:build linux

package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

type clipboardSessionRequest struct {
	Operation string `json:"operation"`
	clipboardRequest
}

var clipboardOwner = struct {
	sync.Mutex
	command *exec.Cmd
}{}

func startClipboardSessionServer(uid uint32) (*net.UnixListener, string, error) {
	runtimeDirectory := os.Getenv("XDG_RUNTIME_DIR")
	expected := filepath.Join("/run/user", strconv.FormatUint(uint64(uid), 10))
	if runtimeDirectory != expected {
		return nil, "", errors.New("invalid XDG_RUNTIME_DIR for session clipboard")
	}
	socketPath := filepath.Join(runtimeDirectory, "ezvm-agent-session.sock")
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
	file, err := os.Open(path)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || uint64(info.Size()) > maximumClipboardBytes {
		file.Close()
		return clipboardResult{Message: "clipboard staging input is invalid"}
	}
	hasher := sha256.New()
	byteCount, err := io.Copy(hasher, io.LimitReader(file, maximumClipboardBytes+1))
	if err != nil || uint64(byteCount) != request.ByteCount || uint64(byteCount) > maximumClipboardBytes {
		file.Close()
		return clipboardResult{Message: "clipboard staging size mismatch"}
	}
	digestText := hex.EncodeToString(hasher.Sum(nil))
	if request.SHA256 != digestText {
		file.Close()
		return clipboardResult{Message: "clipboard staging digest mismatch"}
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		file.Close()
		return clipboardResult{Message: "clipboard staging input is not seekable"}
	}

	clipboardOwner.Lock()
	if clipboardOwner.command != nil && clipboardOwner.command.Process != nil {
		_ = clipboardOwner.command.Process.Kill()
	}
	command := exec.Command("wl-copy", "--foreground", "--type", request.MIMEType)
	command.Stdin = file
	if err := command.Start(); err != nil {
		file.Close()
		clipboardOwner.Unlock()
		return clipboardResult{Message: err.Error()}
	}
	clipboardOwner.command = command
	clipboardOwner.Unlock()
	go func() {
		_ = command.Wait()
		_ = file.Close()
		clipboardOwner.Lock()
		if clipboardOwner.command == command {
			clipboardOwner.command = nil
		}
		clipboardOwner.Unlock()
	}()
	return clipboardResult{Success: true, Message: "Guest clipboard updated.", ByteCount: uint64(byteCount), SHA256: digestText}
}

func getSessionClipboard(path string, request clipboardRequest) clipboardResult {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	temporary := path + ".part"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return clipboardResult{Message: err.Error()}
	}
	defer os.Remove(temporary)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	arguments := []string{"--type", request.MIMEType}
	if request.MIMEType == clipboardTextMIME {
		arguments = append(arguments, "--no-newline")
	}
	command := exec.CommandContext(ctx, "wl-paste", arguments...)
	command.Stdout = file
	command.Stderr = io.Discard
	err = command.Run()
	closeError := file.Close()
	if err != nil || closeError != nil {
		return clipboardResult{Message: "could not read the Wayland clipboard"}
	}
	data, err := os.ReadFile(temporary)
	if err != nil || uint64(len(data)) > maximumClipboardBytes {
		return clipboardResult{Message: "clipboard output is invalid"}
	}
	if err := os.Rename(temporary, path); err != nil {
		return clipboardResult{Message: err.Error()}
	}
	digest := sha256.Sum256(data)
	return clipboardResult{
		Success: true, Message: "Guest clipboard captured.",
		ByteCount: uint64(len(data)), SHA256: hex.EncodeToString(digest[:]),
	}
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
	connection, err := net.DialTimeout("unix", session.socketPath, 2*time.Second)
	if err != nil {
		return clipboardResult{Message: "desktop clipboard session is unavailable"}
	}
	defer connection.Close()
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
