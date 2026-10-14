package extract

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func sandboxed(t *testing.T) (Limited, string) {
	t.Helper()

	confine, err := Sandbox()
	if err != nil {
		t.Skip(err)
	}

	work := t.TempDir()

	return Within(Limited{Confine: confine}, work, 1<<30).(Limited), work
}

func TestSandboxWritesTheWorkFolderAndReadsNothingElse(t *testing.T) {
	run, work := sandboxed(t)

	outside := t.TempDir()
	secret := filepath.Join(outside, "secret.txt")
	if err := os.WriteFile(secret, []byte("hidden"), 0o600); err != nil {
		t.Fatal(err)
	}

	out, err := run.Run(context.Background(), 10*time.Second, "sh", "-c", "echo made > made.txt && cat made.txt")
	if err != nil || strings.TrimSpace(string(out)) != "made" {
		t.Fatalf("the work folder is not writable: %q %v", out, err)
	}

	if _, err := os.Stat(filepath.Join(work, "made.txt")); err != nil {
		t.Fatal(err)
	}

	if out, err := run.Run(context.Background(), 10*time.Second, "cat", secret); err == nil || strings.Contains(string(out), "hidden") {
		t.Fatalf("a file outside the work folder was read: %q", out)
	}

	if _, err := run.Run(context.Background(), 10*time.Second, "sh", "-c", "echo x > "+filepath.Join(outside, "written")); err == nil {
		t.Fatal("a file outside the work folder was written")
	}

	if _, err := os.Stat(filepath.Join(outside, "written")); err == nil {
		t.Fatal("a file outside the work folder exists")
	}

	home, _ := os.UserHomeDir()
	if out, err := run.Run(context.Background(), 10*time.Second, "ls", home); err == nil {
		t.Fatalf("the home folder was listed: %q", out)
	}
}

func TestSandboxReachesNoNetwork(t *testing.T) {
	run, _ := sandboxed(t)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()

	port := strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)

	if _, err := (Limited{}).Run(context.Background(), 10*time.Second, "nc", "-z", "-w", "2", "127.0.0.1", port); err != nil {
		t.Skipf("nc cannot reach the listener even outside the sandbox: %v", err)
	}

	if _, err := run.Run(context.Background(), 10*time.Second, "nc", "-z", "-w", "2", "127.0.0.1", port); err == nil {
		t.Fatal("a sandboxed program reached the network")
	}
}

func TestSandboxCapsFilesAndToleratesTheMissingDataLimit(t *testing.T) {
	run, _ := sandboxed(t)
	run.File = 1 << 20

	out, err := run.Run(context.Background(), 10*time.Second, "sh", "-c", "ulimit -f")
	if err != nil {
		t.Fatal(err)
	}

	if strings.TrimSpace(string(out)) != "2048" {
		t.Fatalf("the file limit is %q", out)
	}
}

func TestSandboxedProgramsStillExtract(t *testing.T) {
	run, work := sandboxed(t)

	pdf := filepath.Join(work, "source.pdf")
	png := filepath.Join(work, "source.png")
	clip := filepath.Join(work, "source.mp4")

	for from, to := range map[string]string{
		"documents/testdata/no-metadata.pdf": pdf,
		"documents/testdata/photo.png":       png,
		"rich/testdata/clip.mp4":             clip,
	} {
		raw, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}

		if err := os.WriteFile(to, raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	cases := []struct {
		program string
		args    []string
		made    string
	}{
		{"pdftotext", []string{pdf, filepath.Join(work, "text.txt")}, "text.txt"},
		{"pdftoppm", []string{"-png", "-r", "30", "-f", "1", "-l", "1", pdf, filepath.Join(work, "page")}, "page-1.png"},
		{"vipsthumbnail", []string{png, "-s", "64", "-o", filepath.Join(work, "thumb.jpg")}, "thumb.jpg"},
		{"tesseract", []string{png, filepath.Join(work, "ocr")}, "ocr.txt"},
		{"ffmpeg", []string{"-v", "error", "-y", "-i", clip, "-frames:v", "1", filepath.Join(work, "frame.jpg")}, "frame.jpg"},
		{"exiftool", []string{"-json", pdf}, ""},
		{"perl", []string{"-MJSON::PP", "-MFile::Temp", "-e", "print 1"}, ""},
	}

	for _, each := range cases {
		t.Run(each.program, func(t *testing.T) {
			if _, err := exec.LookPath(each.program); err != nil {
				t.Skip(err)
			}

			if _, err := run.Run(context.Background(), time.Minute, each.program, each.args...); err != nil {
				t.Fatal(err)
			}

			if each.made == "" {
				return
			}

			if info, err := os.Stat(filepath.Join(work, each.made)); err != nil || info.Size() == 0 {
				t.Fatalf("%s made nothing: %v", each.program, err)
			}
		})
	}
}

func TestSandboxedLibreOfficeConverts(t *testing.T) {
	if os.Getenv("XIXO_SANDBOX_OFFICE") == "" {
		t.Skip("set XIXO_SANDBOX_OFFICE=1 to start LibreOffice; a crash under the sandbox shows a dialog")
	}

	if _, err := exec.LookPath("soffice"); err != nil {
		t.Skip(err)
	}

	run, work := sandboxed(t)

	raw, err := os.ReadFile("documents/testdata/report.docx")
	if err != nil {
		t.Fatal(err)
	}

	source := filepath.Join(work, "report.docx")
	if err := os.WriteFile(source, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	real, _ := filepath.EvalSymlinks(work)
	out := filepath.Join(real, "out")

	if _, err := run.Run(context.Background(), 3*time.Minute, "soffice", "-env:UserInstallation=file://"+filepath.Join(real, "profile"),
		"--headless", "--norestore", "--convert-to", "pdf", "--outdir", out, source); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(out, "report.pdf")); err != nil {
		t.Fatal(err)
	}
}

func TestSandboxReadsASharedFileWhereItLiesAndNothingBesideIt(t *testing.T) {
	run, work := sandboxed(t)

	shared := t.TempDir()
	film := filepath.Join(shared, "Film.mkv")
	beside := filepath.Join(shared, "notes.txt")

	if err := os.WriteFile(film, []byte("frames"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(beside, []byte("private"), 0o644); err != nil {
		t.Fatal(err)
	}

	file, err := os.Open(filepath.Join(shared, "film.mkv"))
	if err != nil {
		file, err = os.Open(film)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	source, err := InPlace(file, work, ".mkv")
	if err != nil {
		t.Fatal(err)
	}

	reading := Reading(run, source)

	if out, err := reading.Run(context.Background(), 10*time.Second, "cat", source.Path); err != nil || string(out) != "frames" {
		t.Fatalf("the shared file was not read: %q %v", out, err)
	}

	if out, err := reading.Run(context.Background(), 10*time.Second, "cat", beside); err == nil || strings.Contains(string(out), "private") {
		t.Fatalf("a file beside the shared file was read: %q", out)
	}

	if _, err := reading.Run(context.Background(), 10*time.Second, "sh", "-c", "echo x >> "+source.Path); err == nil {
		t.Fatal("the shared file was written")
	}

	if body, _ := os.ReadFile(film); string(body) != "frames" {
		t.Fatalf("the shared file holds %q", body)
	}

	if out, err := run.Run(context.Background(), 10*time.Second, "cat", source.Path); err == nil {
		t.Fatalf("a runner that reads no shared file read it: %q", out)
	}
}
