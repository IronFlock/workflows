package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func runOK(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run(args, &out); err != nil {
		t.Fatalf("%v: %v", args, err)
	}
	return out.String()
}

// devCert makes a development key and its certificate in dir.
func devCert(t *testing.T, dir string) (key, cert string) {
	key = filepath.Join(dir, "dev.pem")
	runOK(t, "keygen", "-out", key)
	cert = filepath.Join(dir, "cert.asc")
	armored := runOK(t, "cert", "-public-key", key+".pub", "-created", "2026-10-18T00:00:00Z", "-key-file", key)
	if err := os.WriteFile(cert, []byte(armored), 0o644); err != nil {
		t.Fatal(err)
	}
	return key, cert
}

func TestSignAndVerify(t *testing.T) {
	dir := t.TempDir()
	key, cert := devCert(t, dir)
	files := []string{filepath.Join(dir, "install.sh"), filepath.Join(dir, "version.txt"), filepath.Join(dir, "ironflock-init")}
	for i, f := range files {
		if err := os.WriteFile(f, []byte(strings.Repeat("x", i*1000+1)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	runOK(t, append([]string{"sign", "-cert", cert, "-key-file", key}, files...)...)
	runOK(t, append([]string{"verify", "-cert", cert}, files...)...)

	// The fingerprint depends only on the key and its creation time.
	again := filepath.Join(dir, "again.asc")
	armored := runOK(t, "cert", "-public-key", key+".pub", "-created", "2026-10-18T00:00:00Z", "-key-file", key)
	os.WriteFile(again, []byte(armored), 0o644)
	if a, b := runOK(t, "fingerprint", "-cert", cert), runOK(t, "fingerprint", "-cert", again); a != b {
		t.Errorf("fingerprint changed: %s %s", a, b)
	}

	t.Run("tampered", func(t *testing.T) {
		os.WriteFile(files[1], []byte("9.9.9\n"), 0o644)
		if err := run([]string{"verify", "-cert", cert, files[1]}, &bytes.Buffer{}); err == nil {
			t.Fatal("a changed file verified")
		}
	})
	t.Run("another key", func(t *testing.T) {
		_, other := devCert(t, t.TempDir())
		if err := run([]string{"verify", "-cert", other, files[0]}, &bytes.Buffer{}); err == nil {
			t.Fatal("verified with another key")
		}
	})
	t.Run("gpgv and sqv", func(t *testing.T) {
		exported := strings.TrimSpace(runOK(t, "export", "-cert", cert))
		binary, err := base64.StdEncoding.DecodeString(exported)
		if err != nil {
			t.Fatal(err)
		}
		keyring := filepath.Join(dir, "keyring.gpg")
		os.WriteFile(keyring, binary, 0o644)
		tried := false
		for _, tool := range []string{"gpgv", "sqv"} {
			if _, err := exec.LookPath(tool); err != nil {
				continue
			}
			tried = true
			out, err := exec.Command(tool, "--keyring", keyring, files[0]+".asc", files[0]).CombinedOutput()
			if err != nil {
				t.Errorf("%s: %v\n%s", tool, err, out)
			}
		}
		if !tried {
			t.Skip("neither gpgv nor sqv here; CI runs this on Ubuntu, which has gpgv")
		}
	})
}

// The OpenBao path: a signer command that answers in transit's format, in
// one call for every file.
func TestSignerCommand(t *testing.T) {
	dir := t.TempDir()
	key, cert := devCert(t, dir)
	// A fake transit: signs each digest with the dev key via this binary.
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	calls := filepath.Join(dir, "calls")
	signer := "echo call >> " + calls + "; FAKE_TRANSIT_KEY=" + key + " " + self + " -test.run=TestFakeTransit"
	files := []string{filepath.Join(dir, "a"), filepath.Join(dir, "b")}
	for _, f := range files {
		os.WriteFile(f, []byte(f), 0o644)
	}
	runOK(t, append([]string{"sign", "-cert", cert, "-signer", signer}, files...)...)
	runOK(t, append([]string{"verify", "-cert", cert}, files...)...)
	if data, _ := os.ReadFile(calls); strings.Count(string(data), "call") != 1 {
		t.Errorf("signer called %d times, want once", strings.Count(string(data), "call"))
	}
}

// TestFakeTransit is the signer command TestSignerCommand runs.
func TestFakeTransit(t *testing.T) {
	keyFile := os.Getenv("FAKE_TRANSIT_KEY")
	if keyFile == "" {
		t.Skip("only as a signer command")
	}
	key, err := readPrivateKey(keyFile)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := newBatch("", keyFile, "", &key.PublicKey)
	data, _ := os.ReadFile("/dev/stdin")
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		id, digest, _ := strings.Cut(line, " ")
		raw, _ := base64.StdEncoding.DecodeString(digest)
		sigs, err := b.backend([][]byte{raw})
		if err != nil {
			t.Fatal(err)
		}
		os.Stdout.WriteString(id + " vault:v1:" + base64.StdEncoding.EncodeToString(sigs[0]) + "\n")
	}
	os.Exit(0) // no "PASS" on stdout: that is the answer channel
}
