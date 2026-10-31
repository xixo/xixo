package update

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"slices"
)

const Reads = "PDFs, images, audio, video, and office documents"

type Packages struct {
	Layout
	Run      func(ctx context.Context, name string, args ...string) error
	Out      io.Writer
	LookPath func(name string) (string, error)
}

func (p *Packages) Wanted() ([]string, error) {
	current := Pointed(p.Releases(), Current)
	if current == "" {
		return nil, nil
	}

	held, err := p.Held(current)
	if err != nil {
		return nil, err
	}

	return held.PackagesApt, nil
}

func (p *Packages) Installed() []string {
	held := []string{}
	if Read(p.Packages(), &held) != nil {
		return nil
	}

	return held
}

func (p *Packages) Changed() bool {
	wanted, err := p.Wanted()

	return err == nil && len(wanted) > 0 && !slices.Equal(wanted, p.Installed())
}

func (p *Packages) Install(ctx context.Context) error {
	wanted, err := p.Wanted()
	if err != nil {
		return err
	}

	if len(wanted) == 0 || slices.Equal(wanted, p.Installed()) {
		return nil
	}

	lookPath := p.LookPath
	if lookPath == nil {
		lookPath = exec.LookPath
	}

	if _, err := lookPath("apt-get"); err != nil {
		fmt.Fprintf(p.out(), "   Skipping the programs that read %s, since this system has no apt.\n", Reads)
		fmt.Fprintln(p.out(), "   To read more kinds of files here, install poppler, tesseract, ffmpeg, vips, and LibreOffice.")

		return Write(p.Packages(), wanted, 0o644)
	}

	fmt.Fprintf(p.out(), "   Installing the programs that read %s, with apt. This can take a few minutes.\n", Reads)

	run := p.Run
	if run == nil {
		run = (&Placer{Out: p.Out}).run
	}

	if err := run(ctx, "env", "DEBIAN_FRONTEND=noninteractive", "NEEDRESTART_SUSPEND=1", "apt-get", "-q", "update"); err != nil {
		return fmt.Errorf("apt did not update its lists, so the programs that read %s wait for the next update: %w", Reads, err)
	}

	args := append([]string{"DEBIAN_FRONTEND=noninteractive", "NEEDRESTART_SUSPEND=1", "apt-get", "-q", "install", "-y", "--no-install-recommends", "--"}, wanted...)
	if err := run(ctx, "env", args...); err != nil {
		return fmt.Errorf("apt did not install every program. This machine reads the files it can, and other machines read the rest: %w", err)
	}

	return Write(p.Packages(), wanted, 0o644)
}

func (p *Packages) out() io.Writer {
	if p.Out != nil {
		return p.Out
	}

	return io.Discard
}
