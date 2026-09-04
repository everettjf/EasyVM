package main

import (
	"strings"
	"testing"
)

func TestNotificationCapabilityRequiresDesktopAndOmarchyState(t *testing.T) {
	if actual := notificationCapabilities(true, true); len(actual) != 1 || actual[0] != desktopNotificationCapability {
		t.Fatalf("notification capabilities = %#v", actual)
	}
	if len(notificationCapabilities(false, true)) != 0 || len(notificationCapabilities(true, false)) != 0 {
		t.Fatal("notification capability advertised without an active desktop state directory")
	}
}

func TestDesktopNotificationValidationBoundsUntrustedContent(t *testing.T) {
	value, err := validatedDesktopNotification(desktopNotification{
		ID: "1000-7.json", App: "Browser\x00", Title: "  Build\x01 done  ",
		Body: "line one\nline two\tvalue", Urgency: 99, Timestamp: 1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	if value.App != "Browser" || value.Title != "Build done" || value.Body != "line one\nline two value" {
		t.Fatalf("notification was not sanitized: %#v", value)
	}
	if value.Urgency != 1 {
		t.Fatalf("invalid urgency normalized to %d", value.Urgency)
	}

	long := strings.Repeat("界", maximumNotificationTitleBytes)
	value, err = validatedDesktopNotification(desktopNotification{
		ID: "1000-8.json", Title: long, Timestamp: 1000,
	})
	if err != nil || len(value.Title) > maximumNotificationTitleBytes {
		t.Fatalf("bounded title = %d bytes, error %v", len(value.Title), err)
	}
	if _, err := validatedDesktopNotification(desktopNotification{Title: "missing identity"}); err == nil {
		t.Fatal("notification without identity and timestamp was accepted")
	}
}
