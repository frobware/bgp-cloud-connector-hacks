// Command aws-credential-process mints Red Hat SAML credentials and
// emits them in the form the AWS SDK's credential_process expects, so
// that long-running tools refresh themselves instead of dying when the
// session ends.
//
// The problem it solves: openshift-install holds one set of static
// credentials for the whole run, and the roles that can actually create
// an OIDC provider cap MaxSessionDuration at 3600 seconds. A cluster
// install takes 35-45 minutes. Every install is therefore a race, and
// losing it means finishing by hand.
//
// Wire it up in ~/.aws/config, under a profile name that is NOT the one
// aws-saml.py writes its static keys into, or the static ones win:
//
//	[profile saml-refresh]
//	region = us-east-2
//	credential_process = go run github.com/frobware/bgp-cloud-connector-hacks/cmd/aws-credential-process
//
// Then AWS_PROFILE=saml-refresh, and the SDK re-invokes this whenever
// the credentials near expiry, for as long as the Kerberos ticket lasts.
//
// Configuration is entirely environmental, matching aws-login:
//
//	AWS_ACCOUNT           12-digit account id
//	AWS_ACCOUNT_PASS      pass entry whose first line is the id
//	AWS_ROLE              default <account>-poweruser
//	AWS_SAML_PROFILE      profile aws-saml.py writes to, default saml
//	AWS_SESSION_DURATION  seconds, default 3600
//	AWS_SAML              path to aws-saml.py
//
// Caching matters more than it looks. The SDK invokes credential_process
// per client, so without a cache every single aws call would re-run
// aws-saml.py and hit Kerberos. Credentials are therefore persisted with
// their expiry and only re-minted when genuinely close to expiring.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// credentials is the schema the AWS SDK requires on stdout. Version is
// always 1; the SDK rejects anything else.
type credentials struct {
	Version         int       `json:"Version"`
	AccessKeyID     string    `json:"AccessKeyId"`
	SecretAccessKey string    `json:"SecretAccessKey"`
	SessionToken    string    `json:"SessionToken"`
	Expiration      time.Time `json:"Expiration"`
}

// refreshWindow is how long before expiry we stop trusting cached
// credentials. Generous, because re-minting is cheap and being handed
// credentials that die mid-call is not.
const refreshWindow = 10 * time.Minute

type config struct {
	account  string
	role     string
	profile  string
	duration time.Duration
	samlPath string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "aws-credential-process: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	cachePath, err := cacheFile(cfg)
	if err != nil {
		return err
	}

	if creds, ok := readCache(cachePath); ok {
		return emit(creds)
	}

	// The SDK invokes credential_process per client, so a cold cache can
	// be hit by several processes at once. Without a lock they all run
	// aws-saml.py, all hit Kerberos, and all write the profile and the
	// cache, with a real chance of one reading the file another is
	// half-way through writing.
	//
	// Whoever gets the lock first mints. Everybody else acquires it in
	// turn once the mint has finished, and finds the winner's freshly
	// written cache in the re-check below.
	unlock, err := acquireLock(cachePath+".lock", lockTimeout)
	if err != nil {
		return err
	}
	defer unlock()

	// Re-check: whoever held the lock before us may have just minted.
	if creds, ok := readCache(cachePath); ok {
		return emit(creds)
	}

	creds, err := mint(cfg)
	if err != nil {
		return err
	}

	// A cache we failed to write is not worth failing the whole call
	// over; it only costs a re-mint next time.
	if err := writeCache(cachePath, creds); err != nil {
		fmt.Fprintf(os.Stderr, "aws-credential-process: cache write failed: %v\n", err)
	}

	return emit(creds)
}

func loadConfig() (config, error) {
	cfg := config{
		account:  os.Getenv("AWS_ACCOUNT"),
		role:     os.Getenv("AWS_ROLE"),
		profile:  envOr("AWS_SAML_PROFILE", "saml"),
		samlPath: os.Getenv("AWS_SAML"),
	}

	if cfg.account == "" {
		if entry := os.Getenv("AWS_ACCOUNT_PASS"); entry != "" {
			id, err := passShow(entry)
			if err != nil {
				return cfg, fmt.Errorf("reading account id from pass entry %q: %w", entry, err)
			}
			cfg.account = id
		}
	}
	if cfg.account == "" {
		return cfg, fmt.Errorf("no account id: set AWS_ACCOUNT or AWS_ACCOUNT_PASS")
	}

	if cfg.role == "" {
		cfg.role = cfg.account + "-poweruser"
	}

	secs := 3600
	if v := os.Getenv("AWS_SESSION_DURATION"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return cfg, fmt.Errorf("AWS_SESSION_DURATION %q is not a number: %w", v, err)
		}
		secs = n
	}
	cfg.duration = time.Duration(secs) * time.Second

	if cfg.samlPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return cfg, fmt.Errorf("locating home directory: %w", err)
		}
		cfg.samlPath = filepath.Join(home, ".venvs", "aws-saml", "bin", "aws-saml.py")
	}

	return cfg, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func passShow(entry string) (string, error) {
	out, err := exec.Command("pass", "show", entry).Output()
	if err != nil {
		return "", err
	}
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	if scanner.Scan() {
		if id := strings.TrimSpace(scanner.Text()); id != "" {
			return id, nil
		}
	}
	return "", fmt.Errorf("entry is empty")
}

// mint runs aws-saml.py and reads back what it wrote. aws-saml.py has no
// machine-readable output and records no expiry, so the expiry is
// computed from the duration we asked for. That is the value the role
// granted us unless it capped us, and it caps by refusing outright
// rather than by silently shortening.
func mint(cfg config) (credentials, error) {
	var zero credentials

	if _, err := os.Stat(cfg.samlPath); err != nil {
		return zero, fmt.Errorf("aws-saml.py not found at %s: run aws-install-saml", cfg.samlPath)
	}

	issued := time.Now()

	cmd := exec.Command(cfg.samlPath,
		"--target-account", cfg.account,
		"--target-role", cfg.role,
		"--target-profile", cfg.profile,
		"--session-duration", strconv.Itoa(int(cfg.duration.Seconds())),
	)
	// Never stdout: the SDK parses that, and anything but our JSON is a
	// parse error with a baffling message.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return zero, fmt.Errorf("aws-saml.py failed (is the Kerberos ticket valid? try kinit): %w", err)
	}

	creds, err := readProfile(cfg.profile)
	if err != nil {
		return zero, err
	}
	creds.Version = 1
	creds.Expiration = issued.Add(cfg.duration)
	return creds, nil
}

// readProfile pulls a profile out of the shared credentials file. Written
// by hand rather than pulled from a dependency: the format is three keys
// in a named section, and this is not worth a supply chain.
func readProfile(profile string) (credentials, error) {
	var creds credentials

	path := os.Getenv("AWS_SHARED_CREDENTIALS_FILE")
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return creds, fmt.Errorf("locating home directory: %w", err)
		}
		path = filepath.Join(home, ".aws", "credentials")
	}

	f, err := os.Open(path)
	if err != nil {
		return creds, fmt.Errorf("opening %s: %w", path, err)
	}
	defer f.Close()

	inSection := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			inSection = strings.TrimSuffix(strings.TrimPrefix(line, "["), "]") == profile
			continue
		}
		if !inSection {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch strings.TrimSpace(key) {
		case "aws_access_key_id":
			creds.AccessKeyID = strings.TrimSpace(value)
		case "aws_secret_access_key":
			creds.SecretAccessKey = strings.TrimSpace(value)
		case "aws_session_token":
			creds.SessionToken = strings.TrimSpace(value)
		}
	}
	if err := scanner.Err(); err != nil {
		return creds, fmt.Errorf("reading %s: %w", path, err)
	}

	if creds.AccessKeyID == "" || creds.SecretAccessKey == "" || creds.SessionToken == "" {
		return creds, fmt.Errorf("profile [%s] in %s is missing credentials", profile, path)
	}
	return creds, nil
}

func cacheFile(cfg config) (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("locating cache directory: %w", err)
	}
	dir = filepath.Join(dir, "aws-credential-process")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("creating %s: %w", dir, err)
	}
	// Keyed on everything that changes which credentials you get, so
	// switching role or account does not serve a stale cache. The
	// duration is part of that: it decides the expiry we record, so
	// leaving it out meant asking for a longer session and being handed
	// cached credentials still carrying the shorter one.
	//
	// The components are user input, so flatten path separators: a
	// profile with a slash in it would otherwise aim the cache at a
	// subdirectory that does not exist, every write would fail, and
	// every call would re-mint through Kerberos with only a stderr
	// warning the SDK swallows.
	return filepath.Join(dir, fmt.Sprintf("%s-%s-%s-%d.json",
		flatten(cfg.account), flatten(cfg.role), flatten(cfg.profile),
		int(cfg.duration.Seconds()))), nil
}

func flatten(s string) string { return strings.ReplaceAll(s, "/", "_") }

// lockTimeout bounds how long we wait for another invocation's mint. A
// mint is Kerberos plus a SAML round trip, tens of seconds when the VPN
// is sulking, so this is generous. A holder that dies releases the lock
// immediately, so the full wait is only ever spent on a holder that is
// alive and genuinely stuck.
const lockTimeout = 2 * time.Minute

// acquireLock takes an exclusive advisory lock on path, creating the
// file if needed. flock rather than O_EXCL: the kernel drops an flock
// when its holder exits, however it exits, so a crashed or killed mint
// cannot wedge every later invocation behind a lock file nobody owns.
// The file itself is never removed -- unlinking a locked file races
// against the next acquirer -- it stays as a zero-byte marker beside
// the cache.
//
// Bounded, because a holder genuinely stuck mid-mint would otherwise
// block us for ever while the SDK waits on our stdout.
func acquireLock(path string, timeout time.Duration) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	// Exponential backoff from 1ms, capped at 500ms: a lock released
	// moments after we miss is picked up almost immediately, while a
	// long wait behind a real mint settles into two polls a second
	// rather than spinning.
	backoff := time.Millisecond
	const maxBackoff = 500 * time.Millisecond
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			// Closing the file releases the lock.
			return func() { f.Close() }, nil
		}
		if err != syscall.EWOULDBLOCK {
			f.Close()
			return nil, fmt.Errorf("locking %s: %w", path, err)
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, fmt.Errorf("timed out after %s waiting for the lock on %s: is another mint stuck?", timeout, path)
		}
		time.Sleep(backoff)
		if backoff < maxBackoff {
			backoff *= 2
		}
	}
}

func readCache(path string) (credentials, bool) {
	var creds credentials
	data, err := os.ReadFile(path)
	if err != nil {
		return creds, false
	}
	if err := json.Unmarshal(data, &creds); err != nil {
		return creds, false
	}
	if time.Until(creds.Expiration) < refreshWindow {
		return creds, false
	}
	return creds, true
}

func writeCache(path string, creds credentials) error {
	data, err := json.Marshal(creds)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func emit(creds credentials) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(creds)
}
