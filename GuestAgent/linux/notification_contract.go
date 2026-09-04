package main

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	desktopNotificationCapability = "desktop-notifications-v1"
	maximumDesktopNotifications   = 20
	maximumNotificationIDBytes    = 128
	maximumNotificationAppBytes   = 128
	maximumNotificationTitleBytes = 512
	maximumNotificationBodyBytes  = 4096
)

type desktopNotification struct {
	ID        string `json:"id"`
	App       string `json:"app,omitempty"`
	Title     string `json:"title"`
	Body      string `json:"body,omitempty"`
	Urgency   int    `json:"urgency"`
	Timestamp uint64 `json:"timestamp"`
}

type desktopNotificationBatch struct {
	Success       bool                  `json:"success"`
	Message       string                `json:"message"`
	Notifications []desktopNotification `json:"notifications,omitempty"`
}

type omarchyNotificationSnapshot struct {
	App       string `json:"app"`
	Summary   string `json:"summary"`
	Body      string `json:"body"`
	Urgency   int    `json:"urgency"`
	Timestamp uint64 `json:"timestamp"`
}

func notificationCapabilities(waylandReady, stateDirectoryAvailable bool) []string {
	if !waylandReady || !stateDirectoryAvailable {
		return nil
	}
	return []string{desktopNotificationCapability}
}

func validatedDesktopNotification(value desktopNotification) (desktopNotification, error) {
	value.ID = sanitizeNotificationText(value.ID, maximumNotificationIDBytes, false)
	value.App = sanitizeNotificationText(value.App, maximumNotificationAppBytes, false)
	value.Title = sanitizeNotificationText(value.Title, maximumNotificationTitleBytes, false)
	value.Body = sanitizeNotificationText(value.Body, maximumNotificationBodyBytes, true)
	if value.ID == "" || value.Title == "" || value.Timestamp == 0 {
		return desktopNotification{}, errors.New("notification identity, title, and timestamp are required")
	}
	if value.Urgency < 0 || value.Urgency > 2 {
		value.Urgency = 1
	}
	return value, nil
}

func sanitizeNotificationText(value string, maximumBytes int, preserveNewlines bool) string {
	value = strings.ToValidUTF8(value, "�")
	value = strings.Map(func(character rune) rune {
		if character == '\n' && preserveNewlines {
			return character
		}
		if character == '\t' && preserveNewlines {
			return ' '
		}
		if unicode.IsControl(character) || character == unicode.ReplacementChar {
			return -1
		}
		return character
	}, value)
	value = strings.TrimSpace(value)
	for len(value) > maximumBytes {
		_, width := utf8.DecodeLastRuneInString(value)
		value = value[:len(value)-width]
	}
	return strings.TrimSpace(value)
}
