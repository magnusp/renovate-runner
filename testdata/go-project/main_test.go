package main

import "testing"

func TestNewID(t *testing.T) {
	if len(NewID()) != 36 {
		t.Fatal("unexpected uuid length")
	}
}
