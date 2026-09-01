//go:build linux

package main

import "testing"

func TestRelativePointerDoesNotAdvertiseUnemittedHighResolutionWheel(t *testing.T) {
	for _, code := range relativePointerCodes {
		if code == 11 || code == 12 {
			t.Fatalf("relative pointer advertises high-resolution wheel code %d without emitting it", code)
		}
	}
	foundLegacyWheel := false
	for _, code := range relativePointerCodes {
		if code == 8 {
			foundLegacyWheel = true
		}
	}
	if !foundLegacyWheel {
		t.Fatal("relative pointer no longer advertises REL_WHEEL")
	}
}
