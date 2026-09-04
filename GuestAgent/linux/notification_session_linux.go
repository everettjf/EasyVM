//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"syscall"
	"time"
)

const maximumNotificationSnapshotBytes = 64 * 1024

var omarchyNotificationFilePattern = regexp.MustCompile(`^([0-9]+)-([0-9]+)\.json$`)

func desktopNotificationStateDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) {
		return ""
	}
	return filepath.Join(home, ".local", "state", "omarchy", "notifications")
}

func desktopNotificationStateAvailable(uid uint32) bool {
	directory := desktopNotificationStateDirectory()
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uid
}

func loadDesktopNotifications(directory string, uid uint32) desktopNotificationBatch {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return desktopNotificationBatch{Message: "Omarchy notification state is unavailable."}
	}
	values := make([]desktopNotification, 0, len(entries))
	for _, entry := range entries {
		matches := omarchyNotificationFilePattern.FindStringSubmatch(entry.Name())
		if len(matches) != 3 || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maximumNotificationSnapshotBytes {
			continue
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != uid {
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		// Revalidate the opened descriptor. The desktop user owns this directory
		// and can replace a path between Lstat and Open; only consume the exact
		// regular, owned, bounded file that is now open.
		openedInfo, statError := file.Stat()
		openedStat, statOK := openedInfo.Sys().(*syscall.Stat_t)
		if statError != nil || !openedInfo.Mode().IsRegular() || openedInfo.Size() <= 0 ||
			openedInfo.Size() > maximumNotificationSnapshotBytes || !statOK || openedStat.Uid != uid {
			file.Close()
			continue
		}
		var snapshot omarchyNotificationSnapshot
		decodeError := json.NewDecoder(io.LimitReader(file, maximumNotificationSnapshotBytes+1)).Decode(&snapshot)
		file.Close()
		if decodeError != nil {
			continue
		}
		fileTimestamp, _ := strconv.ParseUint(matches[1], 10, 64)
		if snapshot.Timestamp == 0 {
			snapshot.Timestamp = fileTimestamp
		}
		value, err := validatedDesktopNotification(desktopNotification{
			ID: entry.Name(), App: snapshot.App, Title: snapshot.Summary,
			Body: snapshot.Body, Urgency: snapshot.Urgency, Timestamp: snapshot.Timestamp,
		})
		if err == nil {
			values = append(values, value)
		}
	}
	sort.Slice(values, func(first, second int) bool {
		if values[first].Timestamp == values[second].Timestamp {
			return values[first].ID < values[second].ID
		}
		return values[first].Timestamp < values[second].Timestamp
	})
	if len(values) > maximumDesktopNotifications {
		values = values[len(values)-maximumDesktopNotifications:]
	}
	return desktopNotificationBatch{Success: true, Message: "Current Omarchy notifications captured.", Notifications: values}
}

func proxyDesktopNotifications() desktopNotificationBatch {
	session, ok := activeDesktopSession(time.Now(), desktopNotificationCapability)
	if !ok {
		return desktopNotificationBatch{Message: "no notification-capable desktop session is active"}
	}
	if err := validateDesktopSessionSocket(session); err != nil {
		return desktopNotificationBatch{Message: "desktop notification session is unavailable"}
	}
	rawConnection, err := net.DialTimeout("unix", session.socketPath, 2*time.Second)
	if err != nil {
		return desktopNotificationBatch{Message: "desktop notification session is unavailable"}
	}
	connection, ok := rawConnection.(*net.UnixConn)
	if !ok {
		rawConnection.Close()
		return desktopNotificationBatch{Message: "desktop notification session is unavailable"}
	}
	defer connection.Close()
	peerUID, err := unixPeerUID(connection)
	if err != nil || peerUID != session.uid {
		return desktopNotificationBatch{Message: "desktop notification session identity mismatch"}
	}
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	encoded, _ := json.Marshal(clipboardSessionRequest{Operation: "desktopNotifications"})
	if _, err := connection.Write(append(encoded, '\n')); err != nil {
		return desktopNotificationBatch{Message: err.Error()}
	}
	data, err := bufio.NewReader(io.LimitReader(connection, 128*1024+1)).ReadBytes('\n')
	if err != nil || len(data) > 128*1024 {
		return desktopNotificationBatch{Message: "invalid desktop notification response"}
	}
	var result desktopNotificationBatch
	if json.Unmarshal(data, &result) != nil || !result.Success || len(result.Notifications) > maximumDesktopNotifications {
		return desktopNotificationBatch{Message: "invalid desktop notification response"}
	}
	for index, value := range result.Notifications {
		validated, err := validatedDesktopNotification(value)
		if err != nil {
			return desktopNotificationBatch{Message: "invalid desktop notification response"}
		}
		result.Notifications[index] = validated
	}
	return result
}

func notificationSessionResponse() desktopNotificationBatch {
	directory := desktopNotificationStateDirectory()
	if directory == "" {
		return desktopNotificationBatch{Message: "Omarchy notification state is unavailable."}
	}
	return loadDesktopNotifications(directory, uint32(os.Getuid()))
}
