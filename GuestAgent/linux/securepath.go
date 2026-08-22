package main

type secureUploadTarget interface {
	commit(overwrite bool) error
	cleanup()
}
