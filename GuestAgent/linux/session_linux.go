//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const sessionSocketPath = "/run/ezvm-agent/session.sock"

type sessionRegistration struct {
	UID          uint32   `json:"uid"`
	Capabilities []string `json:"capabilities"`
}

type registeredSession struct {
	capabilities []string
	updatedAt    time.Time
}

var desktopSessions = struct {
	sync.Mutex
	byUID map[uint32]registeredSession
}{byUID: map[uint32]registeredSession{}}

func startSessionRegistry() error {
	if err := os.MkdirAll(filepath.Dir(sessionSocketPath), 0755); err != nil {
		return err
	}
	_ = os.Remove(sessionSocketPath)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: sessionSocketPath, Net: "unix"})
	if err != nil {
		return err
	}
	if err := os.Chmod(sessionSocketPath, 0666); err != nil {
		listener.Close()
		return err
	}
	go func() {
		for {
			connection, err := listener.AcceptUnix()
			if err != nil {
				return
			}
			go acceptSessionRegistration(connection)
		}
	}()
	return nil
}

func acceptSessionRegistration(connection *net.UnixConn) {
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	uid, err := unixPeerUID(connection)
	if err != nil || uid == 0 {
		return
	}
	reader := bufio.NewReader(io.LimitReader(connection, 4097))
	data, err := reader.ReadBytes('\n')
	if err != nil || len(data) > 4096 {
		return
	}
	var registration sessionRegistration
	if json.Unmarshal(data, &registration) != nil || registration.UID != uid {
		return
	}
	capabilities, ok := validatedSessionCapabilities(registration.Capabilities)
	if !ok {
		return
	}
	desktopSessions.Lock()
	desktopSessions.byUID[uid] = registeredSession{capabilities: capabilities, updatedAt: time.Now()}
	desktopSessions.Unlock()
}

func unixPeerUID(connection *net.UnixConn) (uint32, error) {
	raw, err := connection.SyscallConn()
	if err != nil {
		return 0, err
	}
	var credential *syscall.Ucred
	var socketError error
	if err := raw.Control(func(fd uintptr) {
		credential, socketError = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return 0, err
	}
	if socketError != nil || credential == nil {
		return 0, socketError
	}
	return credential.Uid, nil
}

func activeSessionCapabilities(now time.Time) []string {
	desktopSessions.Lock()
	defer desktopSessions.Unlock()
	result := map[string]bool{}
	for uid, session := range desktopSessions.byUID {
		if now.Sub(session.updatedAt) > 15*time.Second {
			delete(desktopSessions.byUID, uid)
			continue
		}
		for _, capability := range session.capabilities {
			result[capability] = true
		}
	}
	values := make([]string, 0, len(result))
	for capability := range result {
		values = append(values, capability)
	}
	sort.Strings(values)
	return values
}

func runSessionAgent() error {
	uid := uint32(os.Getuid())
	if uid == 0 {
		return errors.New("session mode must run as the desktop user")
	}
	for {
		capabilities := detectSessionCapabilities(uid)
		registration := sessionRegistration{UID: uid, Capabilities: capabilities}
		data, err := json.Marshal(registration)
		if err != nil {
			return err
		}
		connection, err := net.DialTimeout("unix", sessionSocketPath, 2*time.Second)
		if err == nil {
			_, err = connection.Write(append(data, '\n'))
			connection.Close()
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "ezvm session registration: %v\n", err)
		}
		time.Sleep(5 * time.Second)
	}
}

func detectSessionCapabilities(uid uint32) []string {
	waylandReady := os.Getenv("WAYLAND_DISPLAY") != "" && os.Getenv("XDG_RUNTIME_DIR") != ""
	spiceConfig, _ := os.ReadFile("/usr/share/spice-guest-tools/config/config.toml")
	spiceRunning := processOwnedBy("spice-vdagent", uid)
	return sessionCapabilities(waylandReady, spiceRunning, spiceConfig)
}

func processOwnedBy(name string, uid uint32) bool {
	entries, _ := filepath.Glob("/proc/[0-9]*/status")
	for _, path := range entries {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		processName := ""
		processUID := uint64(^uint32(0))
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 2 && fields[0] == "Name:" {
				processName = fields[1]
			}
			if len(fields) >= 2 && fields[0] == "Uid:" {
				processUID, _ = strconv.ParseUint(fields[1], 10, 32)
			}
		}
		if processName == name && uint32(processUID) == uid {
			return true
		}
	}
	return false
}
