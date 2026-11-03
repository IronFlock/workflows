// Command sign-openpgp makes the detached OpenPGP signatures an IronFlock
// install or update checks before it runs or uses anything it downloaded:
// device-init's install.sh (version.txt, ironflock-init) and the appliance's
// ironflock-update and installer (install_ironflock.sh, availableVersions.json,
// the release manifest), and the signatures users check those scripts with.
// The private key never leaves its signer — a Cloud KMS key (-kms-key,
// kms.go: what CI signs releases with) or an OpenBao transit key (-signer, by
// hand), RSA-4096 and not exportable: this tool hashes locally and hands only
// digests to the signer.
//
// Detached OpenPGP signatures, because a device can check them with what apt
// already depends on (sqv on Debian 13, gpgv everywhere else) — Ed25519 with
// OpenSSL is not available on Debian 11, Ubuntu 20.04 or Raspberry Pi OS 11.
//
//	cert   [-public-key <pem>] -created <RFC3339> [-uid <name <email>>] <signer>  > cert.asc
//	       (with -kms-key the public key comes from KMS)
//	sign   -cert <cert.asc> <signer> <file>...      writes <file>.asc
//	verify -cert <cert.asc> <file>...               checks <file>.asc
//	export -cert <cert.asc>                         the binary certificate, base64 (install.sh embeds it)
//	fingerprint -cert <cert.asc>
//	keygen -out <key.pem>                           a DEVELOPMENT key (tests, dry runs)
//
// <signer> is -signer '<command>' (reads "<id> <base64 SHA-256 digest>"
// lines, answers "<id> vault:v<N>:<base64 PKCS#1 v1.5 signature>": what
// scripts/openbao-sign-bootstrap.sh does in one OpenBao session),
// -kms-key projects/…/cryptoKeyVersions/<n> (Cloud KMS, Application Default
// Credentials) or -key-file <key.pem> (a development key).
package main

import (
	"bufio"
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ProtonMail/go-crypto/openpgp"
	"github.com/ProtonMail/go-crypto/openpgp/armor"
	"github.com/ProtonMail/go-crypto/openpgp/packet"
)

const defaultUID = "IronFlock Bootstrap <security@ironflock.com>"

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sign-openpgp:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: sign-openpgp cert|sign|verify|export|fingerprint|keygen [flags]")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	certPath := flags.String("cert", "", "the certificate (armored public key)")
	publicKey := flags.String("public-key", "", "cert: the RSA public key, PEM (OpenBao transit/keys/<name> public_key)")
	created := flags.String("created", "", "cert: the key's creation time, RFC 3339 (it is part of the fingerprint)")
	uid := flags.String("uid", defaultUID, "cert: the user ID")
	signerCmd := flags.String("signer", "", "signing command (see the package doc)")
	keyFile := flags.String("key-file", "", "development RSA private key, PEM")
	kmsKey := flags.String("kms-key", "", "Cloud KMS key version resource (projects/…/cryptoKeyVersions/<n>)")
	out := flags.String("out", "", "keygen: the key file to write")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}

	switch args[0] {
	case "keygen":
		return keygen(*out)
	case "cert":
		var pub *rsa.PublicKey
		var err error
		if *publicKey == "" && *kmsKey != "" {
			pub, err = kmsPublicKey(*kmsKey)
		} else {
			pub, err = readPublicKey(*publicKey)
		}
		if err != nil {
			return err
		}
		when, err := time.Parse(time.RFC3339, *created)
		if err != nil {
			return fmt.Errorf("-created: %w", err)
		}
		b, err := newBatch(*signerCmd, *keyFile, *kmsKey, pub)
		if err != nil {
			return err
		}
		return cert(stdout, pub, when.UTC(), *uid, b)
	}

	entity, err := readCert(*certPath)
	if err != nil {
		return err
	}
	switch args[0] {
	case "sign":
		pub, ok := entity.PrimaryKey.PublicKey.(*rsa.PublicKey)
		if !ok {
			return errors.New("the certificate is not an RSA key")
		}
		b, err := newBatch(*signerCmd, *keyFile, *kmsKey, pub)
		if err != nil {
			return err
		}
		return sign(stdout, entity, b, flags.Args())
	case "verify":
		return verify(stdout, entity, flags.Args())
	case "export":
		var buf bytes.Buffer
		if err := entity.Serialize(&buf); err != nil {
			return err
		}
		_, err := fmt.Fprintln(stdout, base64.StdEncoding.EncodeToString(buf.Bytes()))
		return err
	case "fingerprint":
		_, err := fmt.Fprintf(stdout, "%X\n", entity.PrimaryKey.Fingerprint)
		return err
	}
	return fmt.Errorf("unknown subcommand %q", args[0])
}

// config: SHA-256 everywhere (Sequoia's sqv refuses SHA-1), deterministic
// time for the certificate.
func config(now time.Time) *packet.Config {
	return &packet.Config{DefaultHash: crypto.SHA256, Time: func() time.Time { return now }}
}

func cert(stdout io.Writer, pub *rsa.PublicKey, created time.Time, uid string, b *batch) error {
	name, email, ok := strings.Cut(strings.TrimSuffix(uid, ">"), " <")
	if !ok {
		return fmt.Errorf("-uid %q: want \"Name <email>\"", uid)
	}
	primary := packet.NewRSAPublicKey(created, pub)
	entity := &openpgp.Entity{
		PrimaryKey: primary,
		PrivateKey: &packet.PrivateKey{PublicKey: *primary, PrivateKey: b.signer()},
		Identities: map[string]*openpgp.Identity{},
	}
	var err error
	b.run(1, func() { err = entity.AddUserId(name, "", email, config(created)) })
	if b.err != nil {
		return b.err
	}
	if err != nil {
		return err
	}
	w, err := armor.Encode(stdout, openpgp.PublicKeyType, nil)
	if err != nil {
		return err
	}
	if err := entity.Serialize(w); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	_, err = fmt.Fprintln(stdout)
	return err
}

func sign(stdout io.Writer, entity *openpgp.Entity, b *batch, files []string) error {
	if len(files) == 0 {
		return errors.New("sign needs at least one file")
	}
	entity.PrivateKey = &packet.PrivateKey{PublicKey: *entity.PrimaryKey, PrivateKey: b.signer()}
	now := time.Now().UTC()
	sigs := make([]bytes.Buffer, len(files))
	errs := make([]error, len(files))
	data := make([][]byte, len(files))
	for i, file := range files {
		var err error
		if data[i], err = os.ReadFile(file); err != nil { //nolint:gosec // G304: the files to sign are the arguments
			return err
		}
	}
	b.run(len(files), func() {
		var wg sync.WaitGroup
		for i := range files {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				errs[i] = openpgp.ArmoredDetachSign(&sigs[i], entity, bytes.NewReader(data[i]), config(now))
			}(i)
		}
		wg.Wait()
	})
	if err := errors.Join(errs...); err != nil {
		return err
	}
	// go-crypto drops an RSA signer's error (and then fails to serialize):
	// say what the signer said.
	if b.err != nil {
		return b.err
	}
	// Every signature is checked before any is written.
	keyring := openpgp.EntityList{entity}
	for i, file := range files {
		if _, err := openpgp.CheckArmoredDetachedSignature(keyring, bytes.NewReader(data[i]), bytes.NewReader(sigs[i].Bytes()), nil); err != nil {
			return fmt.Errorf("%s: the new signature does not verify: %w", file, err)
		}
	}
	for i, file := range files {
		if err := os.WriteFile(file+".asc", append(sigs[i].Bytes(), '\n'), 0o644); err != nil { //nolint:gosec // G306: a signature is public
			return err
		}
		if _, err := fmt.Fprintf(stdout, "signed %s -> %s.asc\n", file, file); err != nil {
			return err
		}
	}
	return nil
}

func verify(stdout io.Writer, entity *openpgp.Entity, files []string) error {
	if len(files) == 0 {
		return errors.New("verify needs at least one file")
	}
	for _, file := range files {
		data, err := os.ReadFile(file) //nolint:gosec // G304: the files to check are the arguments
		if err != nil {
			return err
		}
		sig, err := os.ReadFile(file + ".asc") //nolint:gosec // G304: their signatures, next to them
		if err != nil {
			return err
		}
		if _, err := openpgp.CheckArmoredDetachedSignature(openpgp.EntityList{entity}, bytes.NewReader(data), bytes.NewReader(sig), nil); err != nil {
			return fmt.Errorf("%s: %w", file, err)
		}
		if _, err := fmt.Fprintf(stdout, "%s: good signature by %X\n", file, entity.PrimaryKey.Fingerprint); err != nil {
			return err
		}
	}
	return nil
}

// --- the batch signer --------------------------------------------------------

// batch collects the digests of n concurrent signing operations and has the
// backend sign them all at once (one OpenBao session), then hands every
// operation its signature.
type batch struct {
	pub     *rsa.PublicKey
	backend func(digests [][]byte) ([][]byte, error)

	err      error // the backend's, of the last run
	mu       sync.Mutex
	want     int
	requests []request
	ready    chan struct{}
}

type request struct {
	digest []byte
	reply  chan result
}

type result struct {
	sig []byte
	err error
}

func newBatch(signerCmd, keyFile, kmsKey string, pub *rsa.PublicKey) (*batch, error) {
	b := &batch{pub: pub}
	given := 0
	for _, s := range []string{signerCmd, keyFile, kmsKey} {
		if s != "" {
			given++
		}
	}
	if given != 1 {
		return nil, errors.New("give exactly one of -signer, -kms-key and -key-file")
	}
	switch {
	case signerCmd != "":
		b.backend = func(digests [][]byte) ([][]byte, error) { return commandSign(signerCmd, digests) }
	case kmsKey != "":
		backend, err := kmsBackend(kmsKey, pub)
		if err != nil {
			return nil, err
		}
		b.backend = backend
	default:
		key, err := readPrivateKey(keyFile)
		if err != nil {
			return nil, err
		}
		if !key.PublicKey.Equal(pub) {
			return nil, errors.New("-key-file is not the certificate's key")
		}
		b.backend = func(digests [][]byte) ([][]byte, error) {
			out := make([][]byte, len(digests))
			for i, d := range digests {
				sig, err := rsa.SignPKCS1v15(nil, key, crypto.SHA256, d)
				if err != nil {
					return nil, err
				}
				out[i] = sig
			}
			return out, nil
		}
	}
	return b, nil
}

// run runs ops, which makes exactly n Sign calls, and answers them together.
func (b *batch) run(n int, ops func()) {
	b.mu.Lock()
	b.want, b.requests, b.ready = n, nil, make(chan struct{})
	b.mu.Unlock()
	done := make(chan struct{})
	go func() { ops(); close(done) }()
	select {
	case <-b.ready:
	case <-done: // an operation failed before it signed
		return
	}
	b.mu.Lock()
	requests := b.requests
	b.requests = nil
	b.mu.Unlock()
	digests := make([][]byte, len(requests))
	for i, r := range requests {
		digests[i] = r.digest
	}
	sigs, err := b.backend(digests)
	b.err = err
	for i, r := range requests {
		if err != nil {
			r.reply <- result{err: err}
		} else {
			r.reply <- result{sig: sigs[i]}
		}
	}
	<-done
}

func (b *batch) signer() crypto.Signer { return batchSigner{b} }

type batchSigner struct{ b *batch }

func (s batchSigner) Public() crypto.PublicKey { return s.b.pub }

func (s batchSigner) Sign(_ io.Reader, digest []byte, opts crypto.SignerOpts) ([]byte, error) {
	if opts.HashFunc() != crypto.SHA256 {
		return nil, fmt.Errorf("asked to sign a %v digest; only SHA-256", opts.HashFunc())
	}
	reply := make(chan result, 1)
	s.b.mu.Lock()
	s.b.requests = append(s.b.requests, request{digest: append([]byte(nil), digest...), reply: reply})
	if len(s.b.requests) == s.b.want {
		close(s.b.ready)
	}
	s.b.mu.Unlock()
	r := <-reply
	return r.sig, r.err
}

// commandSign sends "<i> <base64 digest>" lines to the signer command and
// reads "<i> vault:v<N>:<base64 signature>" answers.
func commandSign(command string, digests [][]byte) ([][]byte, error) {
	var in bytes.Buffer
	for i, d := range digests {
		fmt.Fprintf(&in, "%d %s\n", i, base64.StdEncoding.EncodeToString(d))
	}
	cmd := exec.Command("sh", "-c", command) //nolint:gosec // G204: the signer command is the caller's own (-signer) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	cmd.Stdin = &in
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("signer: %w", err)
	}
	sigs := make([][]byte, len(digests))
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		id, answer, ok := strings.Cut(strings.TrimSpace(scanner.Text()), " ")
		i, err := strconv.Atoi(id)
		if !ok || err != nil || i < 0 || i >= len(sigs) || sigs[i] != nil {
			return nil, fmt.Errorf("unexpected line from the signer: %q", scanner.Text())
		}
		rest, ok := strings.CutPrefix(answer, "vault:v")
		_, encoded, found := strings.Cut(rest, ":")
		if !ok || !found {
			return nil, fmt.Errorf("not a transit signature: %q", answer)
		}
		if sigs[i], err = base64.StdEncoding.DecodeString(encoded); err != nil {
			return nil, fmt.Errorf("not a transit signature: %q", answer)
		}
	}
	for i, s := range sigs {
		if s == nil {
			return nil, fmt.Errorf("the signer did not answer request %d", i)
		}
	}
	return sigs, nil
}

// --- keys ----------------------------------------------------------------------

func keygen(out string) error {
	if out == "" {
		return errors.New("keygen needs -out")
	}
	key, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		return err
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) //nolint:gosec // G304: -out names the key file to write
	if err != nil {
		return err
	}
	if err := pem.Encode(f, &pem.Block{Type: "PRIVATE KEY", Bytes: der}); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return err
	}
	return os.WriteFile(out+".pub", pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}), 0o644) //nolint:gosec // G306: a public key
}

func readPrivateKey(path string) (*rsa.PrivateKey, error) {
	data, err := os.ReadFile(path) //nolint:gosec // G304: -key-file names the key
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("%s: no PEM key", path)
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	rsaKey, ok := key.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s: not an RSA key", path)
	}
	return rsaKey, nil
}

func readPublicKey(path string) (*rsa.PublicKey, error) {
	if path == "" {
		return nil, errors.New("cert needs -public-key or -kms-key")
	}
	data, err := os.ReadFile(path) //nolint:gosec // G304: -public-key names the key
	if err != nil {
		return nil, err
	}
	return parsePublicKeyPEM(data, path)
}

func readCert(path string) (*openpgp.Entity, error) {
	if path == "" {
		return nil, errors.New("-cert is required")
	}
	f, err := os.Open(path) //nolint:gosec // G304: -cert names the certificate
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	entities, err := openpgp.ReadArmoredKeyRing(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if len(entities) != 1 {
		return nil, fmt.Errorf("%s holds %d keys, want 1", path, len(entities))
	}
	return entities[0], nil
}
