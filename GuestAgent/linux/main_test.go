package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestSignedSessionRoundTripAndTampering(t *testing.T) {
	token := bytes.Repeat([]byte{5}, 32)
	session := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32))
	value := makeEnvelope(token, session, 1, "request", "status", []byte("payload"))
	if err := verifyEnvelope(token, session, value, 0); err != nil {
		t.Fatal(err)
	}
	value.Operation = "shutdown"
	if err := verifyEnvelope(token, session, value, 0); err == nil {
		t.Fatal("tampering accepted")
	}
}

func TestReplayAndWrongSessionRejected(t *testing.T) {
	token := bytes.Repeat([]byte{5}, 32)
	value := makeEnvelope(token, "session-a", 1, "request", "heartbeat", nil)
	if err := verifyEnvelope(token, "session-a", value, 1); err == nil {
		t.Fatal("replay accepted")
	}
	if err := verifyEnvelope(token, "session-b", value, 0); err == nil {
		t.Fatal("wrong session accepted")
	}
}

func TestFrameRoundTripAndLimit(t *testing.T) {
	var stream bytes.Buffer
	original := hello{Version: 1, MachineID: "machine", GuestNonce: "nonce", Proof: "proof"}
	if err := writeFrame(&stream, original); err != nil {
		t.Fatal(err)
	}
	var decoded hello
	if err := readFrame(&stream, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded != original {
		t.Fatalf("got %#v", decoded)
	}
	if err := writeFrame(&stream, bytes.Repeat([]byte{0}, maxFrameBytes+1)); err == nil {
		t.Fatal("oversized frame accepted")
	}
}

func TestProtocolMatchesPublishedCrossLanguageVectors(t *testing.T) {
	token := bytes.Repeat([]byte{0x5a}, 32)
	guestNonce := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x11}, 32))
	hostNonce := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x22}, 32))
	if got := sign(token, "guest|1|machine-a|"+guestNonce); got != "Q2bgyj5cc0VI41gARg64PlS3qA7/poair6kJ5ISyz30=" {
		t.Fatalf("guest proof mismatch: %s", got)
	}
	if got := sign(token, "host|1|machine-a|"+guestNonce+"|"+hostNonce); got != "TK3n9Y+ST9leXS55GQaolfhS9ElcRZDY2OHuPvqXndo=" {
		t.Fatalf("host proof mismatch: %s", got)
	}
	value := makeEnvelope(token, "session-a", 7, "request-7", "status", []byte("payload"))
	if value.Proof != "OtNjPmizYoCykrwAy2LUpE2yLnzThrxYkdHq77yVfi4=" {
		t.Fatalf("envelope proof mismatch: %s", value.Proof)
	}
}

func TestServePerformsAuthenticatedHandshakeAndReturnsStatus(t *testing.T) {
	token := bytes.Repeat([]byte{0x4a}, 32)
	config := enrollment{SchemaVersion: 1, MachineID: "integration-machine", Token: token, Port: guestAgentPort}
	host, guest := net.Pipe()
	done := make(chan error, 1)
	input := &recordingInput{available: true, absolute: true}
	go func() { done <- serveWithInput(guest, config, input) }()
	defer host.Close()

	var greeting hello
	if err := readFrame(host, &greeting); err != nil {
		t.Fatal(err)
	}
	if greeting.Version != protocolVersion || greeting.MachineID != config.MachineID {
		t.Fatalf("unexpected greeting: %#v", greeting)
	}
	expectedHello := sign(token, fmt.Sprintf("guest|%d|%s|%s", protocolVersion, config.MachineID, greeting.GuestNonce))
	if !secureEqual(expectedHello, greeting.Proof) {
		t.Fatal("guest authentication failed")
	}
	hostNonce := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32))
	response := welcome{Version: protocolVersion, HostNonce: hostNonce}
	response.Proof = sign(token, fmt.Sprintf("host|%d|%s|%s|%s", protocolVersion, config.MachineID, greeting.GuestNonce, hostNonce))
	if err := writeFrame(host, response); err != nil {
		t.Fatal(err)
	}

	digest := sha256.Sum256([]byte(fmt.Sprintf("session|%s|%s|%s", config.MachineID, greeting.GuestNonce, hostNonce)))
	sessionID := base64.StdEncoding.EncodeToString(digest[:])
	request := makeEnvelope(token, sessionID, 1, "integration-1", "status", nil)
	if err := writeFrame(host, request); err != nil {
		t.Fatal(err)
	}
	var statusEnvelope envelope
	if err := readFrame(host, &statusEnvelope); err != nil {
		t.Fatal(err)
	}
	if err := verifyEnvelope(token, sessionID, statusEnvelope, 0); err != nil {
		t.Fatal(err)
	}
	if statusEnvelope.Operation != "status" || statusEnvelope.RequestID != request.RequestID {
		t.Fatalf("response did not match request: %#v", statusEnvelope)
	}
	var value status
	if err := json.Unmarshal(statusEnvelope.Payload, &value); err != nil {
		t.Fatal(err)
	}
	if value.AgentVersion == "" || value.OperatingSystem == "" || value.KernelVersion == "" {
		t.Fatalf("incomplete status: %#v", value)
	}
	if !contains(value.Capabilities, "input-uinput-v1") {
		t.Fatalf("available input capability was not advertised: %#v", value.Capabilities)
	}
	if !contains(value.Capabilities, "input-uinput-absolute-v1") {
		t.Fatalf("absolute input capability was not advertised: %#v", value.Capabilities)
	}
	if !contains(value.Capabilities, "shutdown-v1") {
		t.Fatalf("authenticated power capability was not advertised: %#v", value.Capabilities)
	}

	inputRequest := makeEnvelope(token, sessionID, 2, "integration-input", "input", inputPayload(t,
		inputEvent{Type: 1, Code: 28, Value: 1}, inputEvent{Type: 0},
	))
	if err := writeFrame(host, inputRequest); err != nil {
		t.Fatal(err)
	}
	var inputEnvelope envelope
	if err := readFrame(host, &inputEnvelope); err != nil {
		t.Fatal(err)
	}
	if err := verifyEnvelope(token, sessionID, inputEnvelope, statusEnvelope.Sequence); err != nil {
		t.Fatal(err)
	}
	var inputResponse inputResult
	if err := json.Unmarshal(inputEnvelope.Payload, &inputResponse); err != nil {
		t.Fatal(err)
	}
	if !inputResponse.Success || len(input.events) != 2 {
		t.Fatalf("authenticated input was not delivered: response=%#v events=%#v", inputResponse, input.events)
	}

	host.Close()
	if err := <-done; err == nil {
		t.Fatal("serve should exit when its host connection closes")
	}
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func TestEnrollmentValidationRequiresExactProtocolValues(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	valid := enrollment{SchemaVersion: 1, MachineID: "machine", Token: bytes.Repeat([]byte{3}, 32), Port: guestAgentPort}
	data, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadEnrollment(path); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*enrollment){
		"schema":  func(value *enrollment) { value.SchemaVersion = 2 },
		"machine": func(value *enrollment) { value.MachineID = "" },
		"token":   func(value *enrollment) { value.Token = []byte("short") },
		"port":    func(value *enrollment) { value.Port = guestAgentPort + 1 },
	} {
		t.Run(name, func(t *testing.T) {
			invalid := valid
			mutate(&invalid)
			encoded, err := json.Marshal(invalid)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, encoded, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := loadEnrollment(path); err == nil {
				t.Fatal("invalid enrollment accepted")
			}
		})
	}
}
