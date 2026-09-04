package main

import "testing"

func TestClipboardRequestAcceptsBoundedIntegrationPaths(t *testing.T) {
	request := clipboardRequest{
		RelativePath: ".ezvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt",
		MIMEType:     clipboardTextMIME,
		ByteCount:    maximumClipboardBytes,
		SHA256:       "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	}
	path, err := validateClipboardRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	expected := "/mnt/ezvm-shared/.ezvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt"
	if path != expected {
		t.Fatalf("path = %q, want %q", path, expected)
	}
}

func TestClipboardRequestRejectsTraversalMIMEAndOversize(t *testing.T) {
	valid := clipboardRequest{
		RelativePath: ".ezvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.png",
		MIMEType:     clipboardImageMIME,
	}
	cases := map[string]clipboardRequest{
		"traversal":      {RelativePath: ".ezvm-clipboard-../secret.png", MIMEType: clipboardImageMIME},
		"nested":         {RelativePath: ".ezvm-integration/clipboard/01234567-89ab-cdef-0123-456789abcdef.png", MIMEType: clipboardImageMIME},
		"absolute":       {RelativePath: "/tmp/01234567-89ab-cdef-0123-456789abcdef.png", MIMEType: clipboardImageMIME},
		"unknown MIME":   {RelativePath: valid.RelativePath, MIMEType: "text/html"},
		"extension":      {RelativePath: valid.RelativePath, MIMEType: clipboardTextMIME},
		"oversize":       {RelativePath: valid.RelativePath, MIMEType: clipboardImageMIME, ByteCount: maximumClipboardBytes + 1},
		"uppercase hash": {RelativePath: valid.RelativePath, MIMEType: clipboardImageMIME, SHA256: "A123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
	}
	for name, request := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := validateClipboardRequest(request); err == nil {
				t.Fatal("request unexpectedly accepted")
			}
		})
	}
}
