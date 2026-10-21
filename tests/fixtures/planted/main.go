// Package main plants findings the security scan must report (negative
// controls): a reachable call into a vulnerable golang.org/x/text version.
// The other plants sit next to it: config.env (fake key), web/log.js (secret
// logged to the console), Dockerfile (outdated base, root user).
package main

import (
	"fmt"

	"golang.org/x/text/language"
)

func main() {
	tags, _, err := language.ParseAcceptLanguage("en-US,en;q=0.9")
	fmt.Println(tags, err)
}
