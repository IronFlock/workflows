// Package fail holds the negative control for the gate: its only test fails,
// so `just test` must exit non-zero.
package fail

import "testing"

func TestPlantedFailure(t *testing.T) {
	t.Fatal("planted failure: the gate must report this test")
}
