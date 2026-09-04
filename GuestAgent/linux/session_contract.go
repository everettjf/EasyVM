package main

import (
	"sort"
	"strings"
)

func sessionCapabilities(waylandReady, spiceRunning bool, spiceConfig []byte) []string {
	if !waylandReady || !spiceRunning || !spiceClipboardEnabled(spiceConfig) {
		return nil
	}
	capabilities := []string{"clipboard-text-v1"}
	if strings.Contains(string(spiceConfig), `derived_formats = ["image/png"]`) {
		capabilities = append(capabilities, "clipboard-image-v1")
	}
	return capabilities
}

func agentClipboardCapabilities(waylandReady, copyAvailable, pasteAvailable bool) []string {
	if !waylandReady || !copyAvailable || !pasteAvailable {
		return nil
	}
	return []string{"clipboard-agent-text-v1", "clipboard-agent-image-v1"}
}

func spiceClipboardEnabled(config []byte) bool {
	section := ""
	for _, raw := range strings.Split(string(config), "\n") {
		line := strings.TrimSpace(strings.SplitN(raw, "#", 2)[0])
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.Trim(line, "[]")
			continue
		}
		if section == "clipboard" && line == "enabled = true" {
			return true
		}
	}
	return false
}

func validatedSessionCapabilities(values []string) ([]string, bool) {
	allowed := map[string]bool{
		"clipboard-text-v1": true, "clipboard-image-v1": true,
		"clipboard-agent-text-v1": true, "clipboard-agent-image-v1": true,
	}
	set := map[string]bool{}
	for _, value := range values {
		if !allowed[value] {
			return nil, false
		}
		set[value] = true
	}
	if set["clipboard-image-v1"] && !set["clipboard-text-v1"] {
		return nil, false
	}
	if set["clipboard-agent-image-v1"] && !set["clipboard-agent-text-v1"] {
		return nil, false
	}
	result := make([]string, 0, len(set))
	for value := range set {
		result = append(result, value)
	}
	sort.Strings(result)
	return result, true
}
