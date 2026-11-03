package main

// The Cloud KMS backend: -kms-key <key version resource> signs every digest
// with an asymmetric KMS key (RSA_SIGN_PKCS1_4096_SHA256, not exportable)
// through the KMS REST API, as the Application Default Credentials (in CI the
// workload identity credentials google-github-actions/auth writes). Only the
// SHA-256 digests leave this process; CRC32C checks guard both directions, as
// KMS recommends.

import (
	"bytes"
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"strconv"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

// kmsAPI is what the signer needs from Cloud KMS; the tests put a fake behind it.
type kmsAPI interface {
	asymmetricSign(ctx context.Context, name string, digest []byte) ([]byte, error)
	publicKey(ctx context.Context, name string) (*rsa.PublicKey, error)
}

// newKMS returns the real client; a variable so the tests can replace it.
var newKMS = func(ctx context.Context) (kmsAPI, error) {
	creds, err := google.FindDefaultCredentials(ctx, "https://www.googleapis.com/auth/cloudkms")
	if err != nil {
		return nil, fmt.Errorf("kms: no Google credentials: %w", err)
	}
	return &kmsREST{client: oauth2.NewClient(ctx, creds.TokenSource), endpoint: "https://cloudkms.googleapis.com/v1/"}, nil
}

type kmsREST struct {
	client   *http.Client
	endpoint string
}

var crc32c = crc32.MakeTable(crc32.Castagnoli)

func (k *kmsREST) call(ctx context.Context, method, path string, body, into any) error {
	var in io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		in = bytes.NewReader(data)
	}
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, k.endpoint+path, in)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return fmt.Errorf("kms: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("kms: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("kms: %s %s: %s: %s", method, path, resp.Status, bytes.TrimSpace(data))
	}
	return json.Unmarshal(data, into)
}

func (k *kmsREST) asymmetricSign(ctx context.Context, name string, digest []byte) ([]byte, error) {
	var answer struct {
		Signature            string `json:"signature"`
		SignatureCrc32c      string `json:"signatureCrc32c"`
		VerifiedDigestCrc32c bool   `json:"verifiedDigestCrc32c"`
		Name                 string `json:"name"`
	}
	request := map[string]any{
		"digest":       map[string]string{"sha256": base64.StdEncoding.EncodeToString(digest)},
		"digestCrc32c": strconv.FormatUint(uint64(crc32.Checksum(digest, crc32c)), 10),
	}
	if err := k.call(ctx, http.MethodPost, name+":asymmetricSign", request, &answer); err != nil {
		return nil, err
	}
	if !answer.VerifiedDigestCrc32c {
		return nil, errors.New("kms: the digest was damaged on the way to KMS")
	}
	if answer.Name != name {
		return nil, fmt.Errorf("kms: signed with %q, not %q", answer.Name, name)
	}
	sig, err := base64.StdEncoding.DecodeString(answer.Signature)
	if err != nil {
		return nil, fmt.Errorf("kms: the signature is not base64: %w", err)
	}
	if strconv.FormatUint(uint64(crc32.Checksum(sig, crc32c)), 10) != answer.SignatureCrc32c {
		return nil, errors.New("kms: the signature was damaged on the way back")
	}
	return sig, nil
}

func (k *kmsREST) publicKey(ctx context.Context, name string) (*rsa.PublicKey, error) {
	var answer struct {
		Pem       string `json:"pem"`
		Algorithm string `json:"algorithm"`
		PemCrc32c string `json:"pemCrc32c"`
	}
	if err := k.call(ctx, http.MethodGet, name+"/publicKey", nil, &answer); err != nil {
		return nil, err
	}
	if answer.Algorithm != "RSA_SIGN_PKCS1_4096_SHA256" {
		return nil, fmt.Errorf("kms: %s is %s, want RSA_SIGN_PKCS1_4096_SHA256", name, answer.Algorithm)
	}
	if answer.PemCrc32c != "" && strconv.FormatUint(uint64(crc32.Checksum([]byte(answer.Pem), crc32c)), 10) != answer.PemCrc32c {
		return nil, errors.New("kms: the public key was damaged on the way")
	}
	return parsePublicKeyPEM([]byte(answer.Pem), name)
}

// kmsBackend signs with the KMS key, after checking that it is the key the
// certificate names (a rotated key version would sign for another cert).
func kmsBackend(name string, pub *rsa.PublicKey) (func([][]byte) ([][]byte, error), error) {
	ctx := context.Background()
	api, err := newKMS(ctx)
	if err != nil {
		return nil, err
	}
	kmsPub, err := api.publicKey(ctx, name)
	if err != nil {
		return nil, err
	}
	if !kmsPub.Equal(pub) {
		return nil, fmt.Errorf("kms: %s is not the certificate's key", name)
	}
	return func(digests [][]byte) ([][]byte, error) {
		out := make([][]byte, len(digests))
		for i, d := range digests {
			sig, err := api.asymmetricSign(ctx, name, d)
			if err != nil {
				return nil, err
			}
			out[i] = sig
		}
		return out, nil
	}, nil
}

// kmsPublicKey fetches the key version's public key (for `cert`).
func kmsPublicKey(name string) (*rsa.PublicKey, error) {
	ctx := context.Background()
	api, err := newKMS(ctx)
	if err != nil {
		return nil, err
	}
	return api.publicKey(ctx, name)
}

func parsePublicKeyPEM(data []byte, source string) (*rsa.PublicKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("%s: no PEM key", source)
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", source, err)
	}
	rsaKey, ok := key.(*rsa.PublicKey)
	if !ok || rsaKey.N.BitLen() < 3072 {
		return nil, fmt.Errorf("%s: not an RSA key of 3072 bits or more", source)
	}
	return rsaKey, nil
}
