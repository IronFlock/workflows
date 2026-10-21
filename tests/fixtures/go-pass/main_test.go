package main

import "testing"

func TestGreeting(t *testing.T) {
	if got := Greeting("x"); got != "hello, x" {
		t.Fatalf("Greeting = %q", got)
	}
}
