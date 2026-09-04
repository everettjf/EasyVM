package main

import (
	"reflect"
	"testing"
)

func TestSessionCapabilitiesRequireWaylandProcessAndEnabledClipboard(t *testing.T) {
	config := []byte("[display]\nenabled = false\n[clipboard]\nenabled = true\nderived_formats = [\"image/png\"]\n")
	expected := []string{"clipboard-text-v1", "clipboard-image-v1"}
	if actual := sessionCapabilities(true, true, config); !reflect.DeepEqual(actual, expected) {
		t.Fatalf("unexpected capabilities: %#v", actual)
	}
	for name, actual := range map[string][]string{
		"no Wayland":    sessionCapabilities(false, true, config),
		"no process":    sessionCapabilities(true, false, config),
		"disabled":      sessionCapabilities(true, true, []byte("[clipboard]\nenabled = false\n")),
		"wrong section": sessionCapabilities(true, true, []byte("[display]\nenabled = true\n")),
	} {
		t.Run(name, func(t *testing.T) {
			if actual != nil {
				t.Fatalf("unready session advertised capabilities: %#v", actual)
			}
		})
	}
}

func TestSessionRegistrationAllowsOnlyDeclaredDesktopCapabilities(t *testing.T) {
	actual, ok := validatedSessionCapabilities([]string{"clipboard-image-v1", "clipboard-text-v1", "clipboard-text-v1"})
	if !ok || !reflect.DeepEqual(actual, []string{"clipboard-image-v1", "clipboard-text-v1"}) {
		t.Fatalf("valid capabilities rejected: %#v %v", actual, ok)
	}
	if _, ok := validatedSessionCapabilities([]string{"arbitrary-host-command-v1"}); ok {
		t.Fatal("unknown session capability was accepted")
	}
	if _, ok := validatedSessionCapabilities([]string{"clipboard-image-v1"}); ok {
		t.Fatal("image clipboard was accepted without the base text capability")
	}
}

func TestAgentClipboardCapabilitiesRequireWaylandAndBothFixedTools(t *testing.T) {
	expected := []string{"clipboard-agent-text-v1", "clipboard-agent-image-v1"}
	if actual := agentClipboardCapabilities(true, true, true); !reflect.DeepEqual(actual, expected) {
		t.Fatalf("Agent clipboard capabilities = %#v", actual)
	}
	for name, actual := range map[string][]string{
		"no Wayland": agentClipboardCapabilities(false, true, true),
		"no copy":    agentClipboardCapabilities(true, false, true),
		"no paste":   agentClipboardCapabilities(true, true, false),
	} {
		t.Run(name, func(t *testing.T) {
			if actual != nil {
				t.Fatalf("unready Agent clipboard advertised capabilities: %#v", actual)
			}
		})
	}
	if _, ok := validatedSessionCapabilities([]string{"clipboard-agent-image-v1"}); ok {
		t.Fatal("Agent image clipboard was accepted without Agent text clipboard")
	}
}
