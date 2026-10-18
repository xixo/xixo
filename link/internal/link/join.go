package link

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	masks "github.com/masksrb/masks/go"
	"github.com/xixo/xixo/link/internal/state"
	"github.com/xixo/xixo/link/internal/terminal"
)

const mostJoining = 16 << 10

type Joining struct {
	EnrollmentToken string `json:"enrollment_token"`
	DeviceCode      string `json:"device_code"`
	Name            string `json:"name"`
}

func ReadJoining(in io.Reader) (Joining, error) {
	raw, err := io.ReadAll(io.LimitReader(in, mostJoining))
	if err != nil {
		return Joining{}, err
	}

	held := Joining{}
	if err := json.Unmarshal(raw, &held); err != nil {
		return Joining{}, errors.New("join reads JSON with enrollment_token and device_code on standard input")
	}

	if held.EnrollmentToken == "" || held.DeviceCode == "" {
		return Joining{}, errors.New("join needs both enrollment_token and device_code")
	}

	return held, nil
}

func Join(ctx context.Context, config *state.Config, held state.State, joining Joining, out io.Writer, options ...masks.Option) (*Linked, error) {
	style := terminal.For(out)

	name := strings.TrimSpace(joining.Name)
	if name == "" {
		name, _ = os.Hostname()
	}

	if _, err := Enroll(ctx, config, held, joining.EnrollmentToken, strings.TrimSpace(name), options...); err != nil {
		return nil, err
	}

	linked, err := bind(ctx, config, held, joining.DeviceCode, options...)
	if err != nil {
		return nil, err
	}

	fmt.Fprintf(out, "   %s Linked up as %s.\n", style.Green("Joined."), style.Bold(linked.Name))

	return linked, nil
}
