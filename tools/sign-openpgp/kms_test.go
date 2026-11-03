package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"hash/crc32"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const testKeyVersion = "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1"

// fakeKMS signs with an in-process RSA key, as KMS would with its own.
type fakeKMS struct {
	key   *rsa.PrivateKey
	signs int
}

func (f *fakeKMS) asymmetricSign(_ context.Context, name string, digest []byte) ([]byte, error) {
	if name != testKeyVersion {
		return nil, os.ErrNotExist
	}
	f.signs++
	return rsa.SignPKCS1v15(nil, f.key, crypto.SHA256, digest)
}

func (f *fakeKMS) publicKey(_ context.Context, name string) (*rsa.PublicKey, error) {
	if name != testKeyVersion {
		return nil, os.ErrNotExist
	}
	return &f.key.PublicKey, nil
}

func useFakeKMS(t *testing.T) *fakeKMS {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeKMS{key: key}
	saved := newKMS
	newKMS = func(context.Context) (kmsAPI, error) { return fake, nil }
	t.Cleanup(func() { newKMS = saved })
	return fake
}

// The KMS path makes the same certificate and signatures as the others:
// the public key comes from KMS, the self-signature and the file signatures
// from KMS, and the existing verify path accepts them.
func TestKMSCertSignVerify(t *testing.T) {
	fake := useFakeKMS(t)
	dir := t.TempDir()
	cert := filepath.Join(dir, "cert.asc")
	armored := runOK(t, "cert", "-kms-key", testKeyVersion, "-created", "2026-10-25T00:00:00Z")
	if err := os.WriteFile(cert, []byte(armored), 0o644); err != nil {
		t.Fatal(err)
	}
	files := []string{filepath.Join(dir, "install.sh"), filepath.Join(dir, "version.txt")}
	for _, f := range files {
		os.WriteFile(f, []byte(f), 0o644)
	}
	before := fake.signs
	runOK(t, append([]string{"sign", "-cert", cert, "-kms-key", testKeyVersion}, files...)...)
	if got := fake.signs - before; got != len(files) {
		t.Errorf("KMS signed %d digests, want %d", got, len(files))
	}
	runOK(t, append([]string{"verify", "-cert", cert}, files...)...)

	t.Run("a KMS key that is not the certificate's", func(t *testing.T) {
		_, other := devCert(t, t.TempDir())
		err := run([]string{"sign", "-cert", other, "-kms-key", testKeyVersion, files[0]}, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "not the certificate's key") {
			t.Fatalf("signed for another certificate: %v", err)
		}
	})
	t.Run("two backends", func(t *testing.T) {
		key, _ := devCert(t, t.TempDir())
		if err := run([]string{"sign", "-cert", cert, "-kms-key", testKeyVersion, "-key-file", key, files[0]}, &bytes.Buffer{}); err == nil {
			t.Fatal("accepted two signing backends")
		}
	})
}

// The REST client against a stand-in for the KMS API: the request KMS
// expects, and the CRC32C checks in both directions.
func TestKMSREST(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	pubPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	crc := func(b []byte) string { return strconv.FormatUint(uint64(crc32.Checksum(b, crc32c)), 10) }

	var damage string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/"+testKeyVersion+"/publicKey":
			json.NewEncoder(w).Encode(map[string]string{"pem": pubPEM, "algorithm": "RSA_SIGN_PKCS1_4096_SHA256", "pemCrc32c": crc([]byte(pubPEM))})
		case r.Method == http.MethodPost && r.URL.Path == "/"+testKeyVersion+":asymmetricSign":
			var req struct {
				Digest       struct{ Sha256 string } `json:"digest"`
				DigestCrc32c string                  `json:"digestCrc32c"`
			}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			digest, _ := base64.StdEncoding.DecodeString(req.Digest.Sha256)
			sig, err := rsa.SignPKCS1v15(nil, key, crypto.SHA256, digest)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			answer := map[string]any{
				"signature":            base64.StdEncoding.EncodeToString(sig),
				"signatureCrc32c":      crc(sig),
				"verifiedDigestCrc32c": req.DigestCrc32c == crc(digest),
				"name":                 testKeyVersion,
			}
			switch damage {
			case "signature":
				answer["signatureCrc32c"] = "1"
			case "digest":
				answer["verifiedDigestCrc32c"] = false
			}
			json.NewEncoder(w).Encode(answer)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	k := &kmsREST{client: srv.Client(), endpoint: srv.URL + "/"}
	ctx := context.Background()

	pub, err := k.publicKey(ctx, testKeyVersion)
	if err != nil {
		t.Fatal(err)
	}
	if !pub.Equal(&key.PublicKey) {
		t.Fatal("wrong public key")
	}
	digest := sha256.Sum256([]byte("version.txt"))
	sig, err := k.asymmetricSign(ctx, testKeyVersion, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], sig); err != nil {
		t.Fatalf("signature does not verify: %v", err)
	}
	for _, d := range []string{"signature", "digest"} {
		damage = d
		if _, err := k.asymmetricSign(ctx, testKeyVersion, digest[:]); err == nil {
			t.Errorf("a damaged %s was accepted", d)
		}
	}
	damage = ""
	if _, err := k.asymmetricSign(ctx, testKeyVersion+"0", digest[:]); err == nil {
		t.Error("an unknown key version answered")
	}
}
