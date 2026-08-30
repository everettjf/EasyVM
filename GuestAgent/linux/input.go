package main

import (
	"encoding/json"
	"errors"
)

const maxInputEvents = 64

type inputEvent struct {
	Type  uint16 `json:"type"`
	Code  uint16 `json:"code"`
	Value int32  `json:"value"`
}

type inputBatch struct {
	Events []inputEvent `json:"events"`
}

type inputResult struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
}

type guestInput interface {
	Available() bool
	Write([]inputEvent) error
	Close() error
}

func decodeInputBatch(payload []byte) ([]inputEvent, error) {
	var batch inputBatch
	if err := json.Unmarshal(payload, &batch); err != nil {
		return nil, errors.New("invalid input payload")
	}
	if len(batch.Events) == 0 || len(batch.Events) > maxInputEvents {
		return nil, errors.New("invalid input event count")
	}
	for index, event := range batch.Events {
		switch event.Type {
		case 0: // EV_SYN
			if event.Code != 0 || event.Value != 0 {
				return nil, errors.New("invalid synchronization event")
			}
		case 1: // EV_KEY
			if event.Code > 767 || event.Value < 0 || event.Value > 2 {
				return nil, errors.New("invalid key event")
			}
		case 2: // EV_REL
			if (event.Code != 0 && event.Code != 1 && event.Code != 8) || event.Value < -32767 || event.Value > 32767 {
				return nil, errors.New("invalid relative pointer event")
			}
		default:
			return nil, errors.New("unsupported input event type")
		}
		if index == len(batch.Events)-1 && event.Type != 0 {
			return nil, errors.New("input batch must end with SYN_REPORT")
		}
	}
	return batch.Events, nil
}

func handleInput(device guestInput, payload []byte) inputResult {
	if device == nil || !device.Available() {
		return inputResult{Message: "uinput is unavailable"}
	}
	events, err := decodeInputBatch(payload)
	if err != nil {
		return inputResult{Message: err.Error()}
	}
	if err := device.Write(events); err != nil {
		return inputResult{Message: "could not inject input"}
	}
	return inputResult{Success: true}
}
