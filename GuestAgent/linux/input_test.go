package main

import (
	"encoding/json"
	"errors"
	"testing"
)

type recordingInput struct {
	available bool
	events    []inputEvent
	err       error
}

func (input *recordingInput) Available() bool { return input.available }
func (input *recordingInput) Write(events []inputEvent) error {
	input.events = append(input.events, events...)
	return input.err
}
func (input *recordingInput) Close() error { return nil }

func inputPayload(t *testing.T, events ...inputEvent) []byte {
	t.Helper()
	payload, err := json.Marshal(inputBatch{Events: events})
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func TestInputBatchValidationAndDelivery(t *testing.T) {
	device := &recordingInput{available: true}
	result := handleInput(device, inputPayload(t,
		inputEvent{Type: 1, Code: 28, Value: 1},
		inputEvent{Type: 2, Code: 0, Value: -12},
		inputEvent{Type: 0, Code: 0, Value: 0},
	))
	if !result.Success || len(device.events) != 3 {
		t.Fatalf("unexpected result: %#v", result)
	}

	bad := handleInput(device, inputPayload(t, inputEvent{Type: 1, Code: 28, Value: 1}))
	if bad.Success {
		t.Fatal("accepted a batch without SYN_REPORT")
	}
	bad = handleInput(device, inputPayload(t,
		inputEvent{Type: 3, Code: 0, Value: 1}, inputEvent{Type: 0},
	))
	if bad.Success {
		t.Fatal("accepted an unsupported event type")
	}
}

func TestInputReportsUnavailableAndWriteFailure(t *testing.T) {
	if handleInput(&recordingInput{}, inputPayload(t, inputEvent{Type: 0})).Success {
		t.Fatal("reported unavailable uinput as successful")
	}
	device := &recordingInput{available: true, err: errors.New("write")}
	if handleInput(device, inputPayload(t, inputEvent{Type: 0})).Success {
		t.Fatal("reported failed uinput write as successful")
	}
}
