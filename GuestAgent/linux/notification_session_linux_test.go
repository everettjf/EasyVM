//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopNotificationLoaderReadsOnlyOwnedCurrentSnapshots(t *testing.T) {
	directory := t.TempDir()
	uid := uint32(os.Getuid())
	for index := 0; index < maximumDesktopNotifications+3; index++ {
		name := fmt.Sprintf("%d-%d.json", 1000+index, index)
		payload := fmt.Sprintf(`{"app":"Browser","summary":"Notice %d","body":"Body","urgency":1,"timestamp":%d}`, index, 1000+index)
		if err := os.WriteFile(filepath.Join(directory, name), []byte(payload), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(directory, "history"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "not-a-notification.json"), []byte(`{"summary":"ignored"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(directory, "1000-0.json"), filepath.Join(directory, "9999-1.json")); err != nil {
		t.Fatal(err)
	}

	batch := loadDesktopNotifications(directory, uid)
	if !batch.Success || len(batch.Notifications) != maximumDesktopNotifications {
		t.Fatalf("notification batch = %#v", batch)
	}
	if batch.Notifications[0].Title != "Notice 3" || batch.Notifications[len(batch.Notifications)-1].Title != "Notice 22" {
		t.Fatalf("notification loader did not retain the newest ordered window: %#v", batch.Notifications)
	}
}

func TestDesktopNotificationLoaderRejectsMalformedAndOversizedSnapshots(t *testing.T) {
	directory := t.TempDir()
	uid := uint32(os.Getuid())
	if err := os.WriteFile(filepath.Join(directory, "1000-1.json"), []byte(`{"summary":`), 0600); err != nil {
		t.Fatal(err)
	}
	oversized := make([]byte, maximumNotificationSnapshotBytes+1)
	if err := os.WriteFile(filepath.Join(directory, "1001-2.json"), oversized, 0600); err != nil {
		t.Fatal(err)
	}
	batch := loadDesktopNotifications(directory, uid)
	if !batch.Success || len(batch.Notifications) != 0 {
		t.Fatalf("unsafe snapshots escaped filtering: %#v", batch)
	}
}
