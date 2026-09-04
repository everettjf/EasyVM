//go:build darwin

package main

func proxyDesktopNotifications() desktopNotificationBatch {
	return desktopNotificationBatch{Message: "desktop notifications are only available on Linux guests"}
}
