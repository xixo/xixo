package link

import (
	"context"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xixo/xixo/link/internal/extract"
	"github.com/xixo/xixo/link/internal/fake"
	"github.com/xixo/xixo/link/internal/folders"
)

func TestHelloAndHealthWarnAboutAFolderTheLinkCannotRead(t *testing.T) {
	folder, _ := shared(t)
	missing := filepath.Join(t.TempDir(), "gone")
	finished := make(chan struct{})

	warned := func(said map[string]any) []string {
		held := []string{}
		listed, _ := said["warnings"].([]any)
		for _, each := range listed {
			held = append(held, each.(string))
		}

		return held
	}

	cable := fake.NewCable(t, "link-token", "", func(socket *fake.Socket) {
		defer close(finished)

		socket.Subscribe(identifier)

		_, hello := socket.Next()
		said := warned(hello)
		if len(said) != 2 || said[0] != "the sandbox is missing" || !strings.Contains(said[1], missing) {
			t.Errorf("hello warnings %v", hello["warnings"])
		}

		needs := map[string]bool{}
		for _, each := range extract.Registered() {
			needs[each.Name()] = len(each.Needs()) > 0
		}

		extractors, _ := hello["extractors"].([]any)
		for _, each := range extractors {
			if needs[each.(string)] {
				t.Errorf("a refusing runner offered %v", each)
			}
		}

		_, health := socket.Next()
		if said := warned(health); len(said) != 2 || !strings.Contains(said[1], missing) {
			t.Errorf("health warnings %v", health["warnings"])
		}

		socket.Close()
	})

	held, dpop := linkFor(t, cable.URL, folder, time.Now().Add(time.Hour))
	cable.Thumbprint = dpop.Thumbprint()
	held.Folders = folders.New(folders.ReadOnly(folder, missing))
	held.Notices = []string{"the sandbox is missing"}
	held.Runner = extract.Limited{Refused: extract.ErrUnconfined}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	held.Session(ctx)
	<-finished
}

func TestUnreadableNamesTheMacOSPermission(t *testing.T) {
	said := Unreadable("/Users/someone/Documents", fs.ErrPermission)

	if !strings.Contains(said, "/Users/someone/Documents") {
		t.Fatalf("got %q", said)
	}

	if strings.Contains(said, "macOS") != (isDarwin) {
		t.Fatalf("got %q", said)
	}
}
