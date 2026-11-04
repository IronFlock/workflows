#!/usr/bin/env bats

load /usr/lib/bats/bats-support/load
load /usr/lib/bats/bats-assert/load

@test "greets by name" {
  run "$BATS_TEST_DIRNAME/../greet.sh" world
  assert_success
  assert_output "hello world"
}

@test "refuses to run without a name" {
  run "$BATS_TEST_DIRNAME/../greet.sh"
  assert_failure
}
