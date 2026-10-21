// Package main is a minimal module the harness self-test gates: it must pass
// lint, unit tests, every cross-build target and the security scan with no
// blocking finding (the positive control).
package main

import "fmt"

// Greeting returns the text main prints.
func Greeting(name string) string {
	return fmt.Sprintf("hello, %s", name)
}

func main() {
	fmt.Println(Greeting("harness"))
}
