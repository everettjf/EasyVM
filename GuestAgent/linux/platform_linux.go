//go:build linux

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type hyprlandSession struct {
	pid        string
	uid        uint32
	gid        uint32
	runtimeDir string
	signature  string
}

func parseHyprlandEnvironment(data []byte) (string, string) {
	var runtimeDir, signature string
	for _, item := range strings.Split(string(data), "\x00") {
		switch {
		case strings.HasPrefix(item, "XDG_RUNTIME_DIR="):
			runtimeDir = strings.TrimPrefix(item, "XDG_RUNTIME_DIR=")
		case strings.HasPrefix(item, "HYPRLAND_INSTANCE_SIGNATURE="):
			signature = strings.TrimPrefix(item, "HYPRLAND_INSTANCE_SIGNATURE=")
		}
	}
	return runtimeDir, signature
}

func parseProcessCredentials(data []byte) (uint32, uint32, bool) {
	var uid, gid uint64
	var haveUID, haveGID bool
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		var err error
		switch fields[0] {
		case "Uid:":
			uid, err = strconv.ParseUint(fields[1], 10, 32)
			haveUID = err == nil
		case "Gid:":
			gid, err = strconv.ParseUint(fields[1], 10, 32)
			haveGID = err == nil
		}
	}
	return uint32(uid), uint32(gid), haveUID && haveGID
}

func hyprlandSignatures(paths ...string) []string {
	seen := make(map[string]bool)
	var signatures []string
	for _, path := range paths {
		entries, _ := os.ReadDir(path)
		for _, entry := range entries {
			if !entry.IsDir() || seen[entry.Name()] {
				continue
			}
			// A stale directory is not a usable Hyprland session.  Both current
			// and older Hyprland releases expose at least one IPC socket here.
			matches, _ := filepath.Glob(filepath.Join(path, entry.Name(), ".socket*.sock"))
			if len(matches) == 0 {
				continue
			}
			seen[entry.Name()] = true
			signatures = append(signatures, entry.Name())
		}
	}
	sort.Strings(signatures)
	return signatures
}

func findHyprlandSessions() []hyprlandSession {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var sessions []hyprlandSession
	for _, entry := range entries {
		pid := entry.Name()
		if !entry.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(pid); err != nil {
			continue
		}
		comm, _ := os.ReadFile("/proc/" + pid + "/comm")
		if !strings.Contains(strings.ToLower(string(comm)), "hyprland") {
			continue
		}
		status, _ := os.ReadFile("/proc/" + pid + "/status")
		uid, gid, ok := parseProcessCredentials(status)
		if !ok {
			continue
		}
		environment, _ := os.ReadFile("/proc/" + pid + "/environ")
		runtimeDir, signature := parseHyprlandEnvironment(environment)
		if runtimeDir == "" {
			runtimeDir = "/run/user/" + strconv.FormatUint(uint64(uid), 10)
		}
		if signature == "" {
			procRoot := "/proc/" + pid + "/root"
			signatures := hyprlandSignatures(
				filepath.Join(runtimeDir, "hypr"),
				filepath.Join(procRoot, runtimeDir, "hypr"),
				"/tmp/hypr",
				filepath.Join(procRoot, "tmp/hypr"),
			)
			if len(signatures) > 0 {
				signature = signatures[len(signatures)-1]
			}
		}
		sessions = append(sessions, hyprlandSession{pid: pid, uid: uid, gid: gid, runtimeDir: runtimeDir, signature: signature})
	}
	return sessions
}

func hyprlandDeviceDiagnostics() string {
	sessions := findHyprlandSessions()
	if len(sessions) == 0 {
		return "hyprctl devices unavailable: Hyprland process not found"
	}
	var failures []string
	for _, session := range sessions {
		if session.signature == "" {
			failures = append(failures, "pid="+session.pid+" has no IPC signature")
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		command := exec.CommandContext(ctx, "hyprctl", "-j", "devices")
		command.Env = append(os.Environ(),
			"XDG_RUNTIME_DIR="+session.runtimeDir,
			"HYPRLAND_INSTANCE_SIGNATURE="+session.signature,
		)
		command.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: session.uid, Gid: session.gid}}
		output, commandErr := command.CombinedOutput()
		cancel()
		if commandErr != nil {
			failures = append(failures, fmt.Sprintf("pid=%s uid=%d signature=%s: %v %s", session.pid, session.uid, session.signature, commandErr, strings.TrimSpace(string(output))))
			continue
		}
		text := string(output)
		index := strings.Index(strings.ToLower(text), "ezvm keyboard")
		if index < 0 {
			return "hyprctl devices has no EZVM Keyboard"
		}
		start := max(0, index-250)
		end := min(len(text), index+650)
		return "hyprctl EZVM Keyboard: " + strings.TrimSpace(text[start:end])
	}
	return "hyprctl devices failed: " + strings.Join(failures, "; ")
}

func desktopInputReady() bool {
	if len(findHyprlandSessions()) > 0 && strings.HasPrefix(hyprlandDeviceDiagnostics(), "hyprctl EZVM Keyboard:") {
		return true
	}
	return intersects(ezvmKeyboardEventDevices(), desktopCompositorInputDevices())
}

func desktopSessionActive() bool {
	compositorPIDs := desktopCompositorPIDs()
	if len(compositorPIDs) == 0 || len(desktopLockerPIDs()) > 0 {
		return false
	}
	if locked, determined := hyprlandSessionLockState(); determined {
		return !locked
	}
	return true
}

func hyprlandSessionLockState() (bool, bool) {
	for _, session := range findHyprlandSessions() {
		if session.signature == "" {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		command := exec.CommandContext(ctx, "hyprctl", "-j", "monitors")
		command.Env = append(os.Environ(),
			"XDG_RUNTIME_DIR="+session.runtimeDir,
			"HYPRLAND_INSTANCE_SIGNATURE="+session.signature,
		)
		command.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: session.uid, Gid: session.gid}}
		output, err := command.Output()
		cancel()
		if err != nil {
			continue
		}
		if locked, determined := parseHyprlandSessionLockState(output); determined {
			return locked, true
		}
	}
	return false, false
}

func parseHyprlandSessionLockState(data []byte) (bool, bool) {
	var monitors []struct {
		SolitaryBlockedBy []string `json:"solitaryBlockedBy"`
	}
	if json.Unmarshal(data, &monitors) != nil || len(monitors) == 0 {
		return false, false
	}
	readable := false
	for _, monitor := range monitors {
		hasWorkspace := false
		for _, blocker := range monitor.SolitaryBlockedBy {
			switch blocker {
			case "LOCK":
				return true, true
			case "WORKSPACE":
				hasWorkspace = true
			}
		}
		if !hasWorkspace {
			readable = true
		}
	}
	if readable {
		return false, true
	}
	return false, false
}

func desktopSessionInteractive(compositorPIDs, lockerPIDs []string) bool {
	return len(compositorPIDs) > 0 && len(lockerPIDs) == 0
}

var desktopCompositorNames = map[string]bool{
	"gnome-shell":  true,
	"hyprland":     true,
	"kwin_wayland": true,
	"sway":         true,
	"weston":       true,
}

var desktopLockerNames = map[string]bool{
	"hyprlock": true,
}

func desktopCompositorPIDs() []string {
	return desktopProcessPIDs(desktopCompositorNames)
}

func desktopLockerPIDs() []string {
	return desktopProcessPIDs(desktopLockerNames)
}

func desktopProcessPIDs(names map[string]bool) []string {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var pids []string
	for _, entry := range entries {
		pid := entry.Name()
		if !entry.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(pid); err != nil {
			continue
		}
		name := strings.ToLower(readTrimmed("/proc/" + pid + "/comm"))
		if names[name] {
			pids = append(pids, pid)
		}
	}
	return pids
}

func desktopCompositorInputDevices() []string {
	seen := make(map[string]bool)
	var devices []string
	for _, pid := range desktopCompositorPIDs() {
		fds, _ := os.ReadDir("/proc/" + pid + "/fd")
		for _, fd := range fds {
			target, err := os.Readlink("/proc/" + pid + "/fd/" + fd.Name())
			if err != nil || !strings.HasPrefix(target, "/dev/input/event") {
				continue
			}
			device := strings.TrimPrefix(target, "/dev/input/")
			if !seen[device] {
				seen[device] = true
				devices = append(devices, device)
			}
		}
	}
	sort.Strings(devices)
	return devices
}

func ezvmKeyboardEventDevices() []string {
	data, err := os.ReadFile("/proc/bus/input/devices")
	if err != nil {
		return nil
	}
	var devices []string
	for _, block := range strings.Split(string(data), "\n\n") {
		if !strings.Contains(block, `N: Name="EZVM Keyboard"`) {
			continue
		}
		for _, line := range strings.Split(block, "\n") {
			if !strings.HasPrefix(line, "H: Handlers=") {
				continue
			}
			for _, field := range strings.Fields(strings.TrimPrefix(line, "H: Handlers=")) {
				if strings.HasPrefix(field, "event") {
					devices = append(devices, field)
				}
			}
		}
	}
	return devices
}

func intersects(left, right []string) bool {
	values := make(map[string]bool, len(left))
	for _, value := range left {
		values[value] = true
	}
	for _, value := range right {
		if values[value] {
			return true
		}
	}
	return false
}

type sockaddrVM struct {
	Family   uint16
	Reserved uint16
	Port     uint32
	CID      uint32
	Flags    uint8
	Zero     [3]uint8
}

// AF_VSOCK is part of Linux's UAPI, but the frozen syscall package does not
// expose it on every architecture/toolchain combination used by CI.
const addressFamilyVSock = 40

func listenVSock(port uint32) (int, error) {
	fd, err := syscall.Socket(addressFamilyVSock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	address := sockaddrVM{Family: addressFamilyVSock, Port: port, CID: vmaddrCIDAny}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&address)), unsafe.Sizeof(address))
	if errno != 0 {
		syscall.Close(fd)
		return -1, errno
	}
	if err := syscall.Listen(fd, 4); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	return fd, nil
}

func acceptSocket(fd int) (int, error) {
	for {
		// syscall.Accept asks the Go syscall package to decode the peer
		// sockaddr. Its legacy Linux decoder does not understand AF_VSOCK and
		// returns EAFNOSUPPORT after the kernel has accepted the connection.
		// The agent does not use the peer address, so omit it at the syscall
		// boundary and retain close-on-exec atomically.
		connection, _, errno := syscall.Syscall6(
			syscall.SYS_ACCEPT4, uintptr(fd), 0, 0, syscall.SOCK_CLOEXEC, 0, 0,
		)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return -1, errno
		}
		return int(connection), nil
	}
}

func closeSocket(fd int) { _ = syscall.Close(fd) }

type fdStream struct{ fd int }

func (stream fdStream) Read(p []byte) (int, error) { return syscall.Read(stream.fd, p) }
func (stream fdStream) Write(p []byte) (int, error) {
	written := 0
	for written < len(p) {
		count, err := syscall.Write(stream.fd, p[written:])
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return written, err
		}
		if count == 0 {
			return written, syscall.EIO
		}
		written += count
	}
	return written, nil
}

func power(operation string) {
	time.Sleep(250 * time.Millisecond)
	argument := "poweroff"
	if operation == "restart" {
		argument = "reboot"
	}
	if err := exec.Command("systemctl", argument).Run(); err == nil {
		return
	}
	_ = exec.Command("/sbin/" + argument).Run()
}
