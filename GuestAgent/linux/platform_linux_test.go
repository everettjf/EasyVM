//go:build linux

package main

import "testing"

func TestParseHyprlandEnvironment(t *testing.T) {
	runtimeDir, signature := parseHyprlandEnvironment([]byte("PATH=/usr/bin\x00XDG_RUNTIME_DIR=/run/user/1000\x00HYPRLAND_INSTANCE_SIGNATURE=abc_123\x00"))
	if runtimeDir != "/run/user/1000" {
		t.Fatalf("runtime directory = %q", runtimeDir)
	}
	if signature != "abc_123" {
		t.Fatalf("signature = %q", signature)
	}
}

func TestParseProcessCredentials(t *testing.T) {
	uid, gid, ok := parseProcessCredentials([]byte("Name:\tHyprland\nUid:\t1000\t1000\t1000\t1000\nGid:\t984\t984\t984\t984\n"))
	if !ok || uid != 1000 || gid != 984 {
		t.Fatalf("credentials = (%d, %d, %t)", uid, gid, ok)
	}
}

func TestParseProcessCredentialsRejectsIncompleteStatus(t *testing.T) {
	if _, _, ok := parseProcessCredentials([]byte("Uid:\t1000\t1000\t1000\t1000\n")); ok {
		t.Fatal("incomplete process credentials were accepted")
	}
}
