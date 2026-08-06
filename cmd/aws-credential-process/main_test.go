package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"testing/synctest"
	"time"
)

// Cache key components are user input (AWS_SAML_PROFILE and friends);
// a path separator in one must not point the cache at a subdirectory
// that does not exist, or every call silently re-mints.
func TestCacheFileFlattensPathSeparators(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheRoot)

	path, err := cacheFile(config{
		account:  "123456789012",
		role:     "team/poweruser",
		profile:  "org/saml",
		duration: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(cacheRoot, "aws-credential-process")
	if got := filepath.Dir(path); got != want {
		t.Fatalf("cache file landed in %s, want %s", got, want)
	}
	if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
		t.Fatalf("cache path is not writable: %v", err)
	}
}

// A lock file left behind by a crashed or killed holder is just a
// file: the process that created it is gone, so nothing holds it.
// Acquiring must succeed, or one Ctrl-C during a mint wedges every
// later cold-cache invocation for ever.
func TestAcquireLockIgnoresStaleLockFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.lock")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	unlock, err := acquireLock(path, time.Second)
	if err != nil {
		t.Fatalf("acquireLock with a stale lock file: %v", err)
	}
	unlock()
}

// Release must actually release: a second acquisition on the same path
// succeeds once the first unlock has run.
func TestAcquireLockSequential(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.lock")
	for i := range 2 {
		unlock, err := acquireLock(path, time.Second)
		if err != nil {
			t.Fatalf("acquire %d: %v", i, err)
		}
		unlock()
	}
}

// A lock somebody genuinely holds is waited for, then given up on.
// flock contends between file descriptions, so a second open in the
// same process stands in for another process here. The acquire loop
// blocks only on time.Sleep, so synctest runs the whole wait on a
// fake clock and the assertions are exact rather than racy.
func TestAcquireLockTimesOutWhileHeld(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.lock")
	holder, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	if err := syscall.Flock(int(holder.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}

	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		if _, err := acquireLock(path, 500*time.Millisecond); err == nil {
			t.Fatal("acquired a lock somebody else holds")
		}
		if waited := time.Since(start); waited < 500*time.Millisecond {
			t.Fatalf("gave up after %v, before the timeout", waited)
		}
	})
}

// Once the holder lets go, a waiter blocked on the lock gets it well
// inside its timeout.
func TestAcquireLockWaitsForRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.lock")

	synctest.Test(t, func(t *testing.T) {
		holder, err := acquireLock(path, time.Second)
		if err != nil {
			t.Fatal(err)
		}

		done := make(chan error, 1)
		go func() {
			unlock, err := acquireLock(path, 30*time.Second)
			if err == nil {
				unlock()
			}
			done <- err
		}()

		time.Sleep(10 * time.Second)
		holder()
		if err := <-done; err != nil {
			t.Fatalf("waiter never got the released lock: %v", err)
		}
	})
}
