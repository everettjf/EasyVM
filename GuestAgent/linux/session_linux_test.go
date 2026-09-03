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
