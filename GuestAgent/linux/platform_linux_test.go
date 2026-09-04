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

func TestIntersectsInputDeviceSets(t *testing.T) {
	if !intersects([]string{"event3", "event4"}, []string{"event1", "event3"}) {
		t.Fatal("shared input event was not detected")
	}
	if intersects([]string{"event3"}, []string{"event1", "event2"}) {
		t.Fatal("disjoint input devices were accepted")
	}
}

func TestDesktopSessionRequiresCompositorWithoutActiveLocker(t *testing.T) {
	if !desktopSessionInteractive([]string{"101"}, nil) {
		t.Fatal("unlocked compositor was not reported as interactive")
	}
	if desktopSessionInteractive([]string{"101"}, []string{"202"}) {
		t.Fatal("locked compositor was reported as interactive")
	}
	if desktopSessionInteractive(nil, nil) {
		t.Fatal("missing compositor was reported as interactive")
	}
}

func TestParseHyprlandSessionLockState(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		locked     bool
		determined bool
	}{
		{"locked", `[{"solitaryBlockedBy":["LOCK"]}]`, true, true},
		{"locked among monitors", `[{"solitaryBlockedBy":["WORKSPACE"]},{"solitaryBlockedBy":["LOCK"]}]`, true, true},
		{"unlocked", `[{"solitaryBlockedBy":[]}]`, false, true},
		{"unlocked with another blocker", `[{"solitaryBlockedBy":["MIRROR"]}]`, false, true},
		{"workspace only is undetermined", `[{"solitaryBlockedBy":["WORKSPACE"]}]`, false, false},
		{"empty is undetermined", `[]`, false, false},
		{"invalid is undetermined", `{`, false, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			locked, determined := parseHyprlandSessionLockState([]byte(test.input))
			if locked != test.locked || determined != test.determined {
				t.Fatalf("got (%t, %t), want (%t, %t)", locked, determined, test.locked, test.determined)
			}
		})
	}
}
