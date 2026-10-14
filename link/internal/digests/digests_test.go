package digests

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var sum = strings.Repeat("ab", 32)

func stampOf(t *testing.T, path string) Stamp {
	t.Helper()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	stamp, ok := Of(info)
	if !ok {
		t.Skip("this system gives files no identity")
	}

	return stamp
}

func TestAStampChangesWithEveryWriteEvenWhenSizeAndTimeAreKept(t *testing.T) {
	path := filepath.Join(t.TempDir(), "film.mkv")
	os.WriteFile(path, []byte("aaaa"), 0o600)
	before := stampOf(t, path)

	time.Sleep(20 * time.Millisecond)
	os.WriteFile(path, []byte("bbbb"), 0o600)
	modified := time.Unix(0, before.Modified)
	os.Chtimes(path, modified, modified)
	after := stampOf(t, path)

	if after.Size != before.Size || after.Modified != before.Modified || after.File != before.File {
		t.Fatalf("the file should keep its size, time, and identity: %+v %+v", before, after)
	}

	if after == before {
		t.Fatal("a rewrite keeps the same stamp")
	}
}

func TestADigestIsKnownOnlyForTheSameStamp(t *testing.T) {
	cache := &Cache{Smallest: 1}
	stamp := Stamp{File: "1:2", Size: 10, Modified: 3, Changed: 4}
	cache.Note(stamp, sum)

	if got, ok := cache.Known(stamp); !ok || got != sum {
		t.Fatalf("known %q %v", got, ok)
	}

	for _, other := range []Stamp{
		{File: "1:2", Size: 11, Modified: 3, Changed: 4},
		{File: "1:2", Size: 10, Modified: 5, Changed: 4},
		{File: "1:2", Size: 10, Modified: 3, Changed: 6},
		{File: "1:3", Size: 10, Modified: 3, Changed: 4},
	} {
		if _, ok := cache.Known(other); ok {
			t.Errorf("%+v is known", other)
		}
	}
}

func TestSmallFilesAndBadDigestsAreNotKept(t *testing.T) {
	cache := &Cache{}
	cache.Note(Stamp{File: "1:2", Size: Smallest - 1}, sum)
	cache.Note(Stamp{File: "1:3", Size: Smallest}, "not a digest")
	cache.Note(Stamp{Size: Smallest}, sum)

	if len(cache.held) != 0 {
		t.Fatalf("kept %v", cache.held)
	}
}

func TestTheCacheIsSavedAndReadBack(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache", "digests.json")
	stamp := Stamp{File: "1:2", Size: Smallest, Modified: 3, Changed: 4}

	first := &Cache{Path: path}
	first.Note(stamp, sum)

	if err := first.Save(); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("saved %v %v", info, err)
	}

	second := &Cache{Path: path}
	if got, ok := second.Known(stamp); !ok || got != sum {
		t.Fatalf("read back %q %v", got, ok)
	}
}

func TestADamagedCacheStartsEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "digests.json")
	os.WriteFile(path, []byte(`{"format":1,"files":[{"file":"1:2","size":1,"sha256":"../../etc"}]}`), 0o600)

	cache := &Cache{Path: path}
	if _, ok := cache.Known(Stamp{File: "1:2", Size: 1}); ok {
		t.Fatal("a damaged entry is known")
	}

	os.WriteFile(path, []byte("{"), 0o600)

	if _, ok := (&Cache{Path: path}).Known(Stamp{File: "1:2"}); ok {
		t.Fatal("a damaged file is read")
	}
}

func TestTheLeastRecentlyUsedAreForgottenPastTheMost(t *testing.T) {
	cache := &Cache{Smallest: 1, Most: 10}

	for i := range 20 {
		cache.Note(Stamp{File: string(rune('a' + i)), Size: 1}, sum)
	}

	if len(cache.held) > 10 {
		t.Fatalf("kept %d", len(cache.held))
	}
}

func TestOneFileIsHashedOnceWhenAskedManyTimesAtOnce(t *testing.T) {
	cache := &Cache{Smallest: 1}
	stamp := Stamp{File: "1:2", Size: 100}
	hashes := atomic.Int32{}
	release := make(chan struct{})
	group := sync.WaitGroup{}

	for range 5 {
		group.Go(func() {
			got, err := cache.Digest(context.Background(), stamp, func() (string, int64, Stamp, error) {
				hashes.Add(1)
				<-release

				return sum, 100, stamp, nil
			})
			if err != nil || got != sum {
				t.Errorf("digest %q %v", got, err)
			}
		})
	}

	time.Sleep(50 * time.Millisecond)
	close(release)
	group.Wait()

	if hashes.Load() != 1 || cache.Hashed() != 100 {
		t.Fatalf("hashed %d times, %d bytes", hashes.Load(), cache.Hashed())
	}

	again, _ := cache.Digest(context.Background(), stamp, func() (string, int64, Stamp, error) {
		t.Fatal("a known file is hashed again")

		return "", 0, Stamp{}, nil
	})

	if again != sum {
		t.Fatalf("again %q", again)
	}
}

func TestAFileThatChangedWhileHashedIsNotRemembered(t *testing.T) {
	cache := &Cache{Smallest: 1}
	stamp := Stamp{File: "1:2", Size: 100}
	moved := Stamp{File: "1:2", Size: 100, Changed: 1}

	cache.Digest(context.Background(), stamp, func() (string, int64, Stamp, error) { return sum, 100, moved, nil })

	if _, ok := cache.Known(stamp); ok {
		t.Fatal("a moving file is remembered")
	}

	failed := errors.New("unreadable")

	if _, err := cache.Digest(context.Background(), stamp, func() (string, int64, Stamp, error) { return "", 0, stamp, failed }); !errors.Is(err, failed) {
		t.Fatalf("error %v", err)
	}

	if _, ok := cache.Known(stamp); ok {
		t.Fatal("a failed hash is remembered")
	}
}

func TestAWaiterHashesTheFileItselfWhenTheFirstAskerIsStopped(t *testing.T) {
	cache := &Cache{Smallest: 1}
	stamp := Stamp{File: "1:3", Size: 100}
	first, stop := context.WithCancel(context.Background())
	reading := make(chan struct{})
	led := make(chan error, 1)

	go func() {
		_, err := cache.Digest(first, stamp, func() (string, int64, Stamp, error) {
			close(reading)
			<-first.Done()

			return "", 0, stamp, first.Err()
		})
		led <- err
	}()

	<-reading

	waited := make(chan string, 1)

	go func() {
		got, err := cache.Digest(context.Background(), stamp, func() (string, int64, Stamp, error) {
			return sum, 100, stamp, nil
		})
		if err != nil {
			t.Errorf("the waiter got %v", err)
		}
		waited <- got
	}()

	time.Sleep(50 * time.Millisecond)
	stop()

	if err := <-led; !errors.Is(err, context.Canceled) {
		t.Fatalf("the stopped asker got %v", err)
	}

	if got := <-waited; got != sum {
		t.Fatalf("the waiter got %q", got)
	}
}
