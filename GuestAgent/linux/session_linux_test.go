//go:build linux

package main

import (
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestUnixSessionPeerUIDComesFromKernelCredentials(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	result := make(chan uint32, 1)
	go func() {
		connection, err := listener.AcceptUnix()
		if err != nil {
			result <- ^uint32(0)
			return
		}
		defer connection.Close()
		uid, err := unixPeerUID(connection)
		if err != nil {
			result <- ^uint32(0)
			return
		}
		result <- uid
	}()
	connection, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	connection.Close()
	if actual := <-result; actual != uint32(os.Getuid()) {
		t.Fatalf("kernel peer UID = %d, process UID = %d", actual, os.Getuid())
	}
}

func TestDesktopSessionRegistrationsExpire(t *testing.T) {
	now := time.Now()
	desktopSessions.Lock()
	desktopSessions.byUID = map[uint32]registeredSession{
		1000: {capabilities: []string{"clipboard-text-v1"}, updatedAt: now},
		1001: {capabilities: []string{"clipboard-image-v1"}, updatedAt: now.Add(-16 * time.Second)},
	}
	desktopSessions.Unlock()
	if actual := activeSessionCapabilities(now); !reflect.DeepEqual(actual, []string{"clipboard-text-v1"}) {
		t.Fatalf("active capabilities = %#v", actual)
	}
}

func TestInvalidDesktopSessionRegistrationDoesNotPoisonRegistry(t *testing.T) {
	now := time.Now()
	desktopSessions.Lock()
	desktopSessions.byUID = map[uint32]registeredSession{}
	desktopSessions.Unlock()

	invalid := sessionRegistration{
		UID:          1000,
		Capabilities: []string{"clipboard-agent-text-v1"},
		SocketPath:   "/tmp/untrusted-session.sock",
	}
	if storeSessionRegistration(1000, invalid, now) {
		t.Fatal("accepted an untrusted session socket path")
	}
	valid := invalid
	valid.SocketPath = "/run/user/1000/ezvm-agent-session.sock"
	if !storeSessionRegistration(1000, valid, now) {
		t.Fatal("valid session registration was rejected after invalid input")
	}
	if actual := activeSessionCapabilities(now); !reflect.DeepEqual(actual, []string{"clipboard-agent-text-v1"}) {
		t.Fatalf("active capabilities = %#v", actual)
	}
}

func TestActiveDesktopSessionRequiresCapabilityAndSocket(t *testing.T) {
	now := time.Now()
	desktopSessions.Lock()
	desktopSessions.byUID = map[uint32]registeredSession{
		1000: {
			capabilities: []string{"clipboard-agent-text-v1"},
			socketPath:   "/run/user/1000/ezvm-agent-session.sock",
			updatedAt:    now.Add(-time.Second),
		},
		1001: {
			capabilities: []string{"clipboard-agent-text-v1", "clipboard-agent-image-v1"},
			socketPath:   "/run/user/1001/ezvm-agent-session.sock",
			updatedAt:    now,
		},
	}
	desktopSessions.Unlock()
	session, ok := activeDesktopSession(now, "clipboard-agent-image-v1")
	if !ok || session.socketPath != "/run/user/1001/ezvm-agent-session.sock" {
		t.Fatalf("wrong active image clipboard session: %#v %v", session, ok)
	}
	if _, ok := activeDesktopSession(now, "arbitrary-host-command-v1"); ok {
		t.Fatal("unknown capability selected a desktop session")
	}
}
