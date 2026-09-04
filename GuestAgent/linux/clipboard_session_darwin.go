//go:build darwin

package main

func proxyClipboardRequest(_ string, _ []byte) clipboardResult {
	return clipboardResult{Message: "desktop clipboard is only available on Linux guests"}
}
