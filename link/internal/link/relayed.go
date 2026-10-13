package link

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	RelayStallsAfter = 2 * time.Minute
	relayTries       = 4
	relayLongestWait = time.Second
)

var ErrRelayStalled = errors.New("xixo sent no part of the upload for two minutes")

func (a *Link) relayed(ctx context.Context, upload string, size int64, into io.Writer) error {
	target := strings.TrimSuffix(a.Xixo, "/") + "/link/uploads/" + upload
	received := int64(0)
	moved := time.Now()
	wait := time.Duration(0)
	failures := 0

	for received < size {
		response, err := a.part(ctx, target, received)
		if err != nil {
			if ctx.Err() != nil {
				return err
			}

			failures++
			if failures >= relayTries {
				return err
			}

			if err := pause(ctx, time.Duration(failures)*time.Second); err != nil {
				return err
			}

			continue
		}

		switch response.StatusCode {
		case http.StatusOK:
			copied, err := io.Copy(into, io.LimitReader(response.Body, size-received+1))
			response.Body.Close()
			received += copied

			if received > size {
				return ErrUploadSize
			}

			if copied > 0 {
				moved = time.Now()
				wait = 0
				failures = 0
			}

			if errors.Is(err, io.ErrClosedPipe) {
				return err
			}

			if err != nil {
				failures++
				if failures >= relayTries {
					return err
				}
			}
		case http.StatusNoContent:
			response.Body.Close()

			if time.Since(moved) > RelayStallsAfter {
				return ErrRelayStalled
			}

			wait = min(max(wait*2, 50*time.Millisecond), relayLongestWait)
			if err := pause(ctx, wait); err != nil {
				return err
			}
		default:
			response.Body.Close()

			return fmt.Errorf("xixo answered the upload with %s", response.Status)
		}
	}

	return nil
}

func (a *Link) part(ctx context.Context, target string, from int64) (*http.Response, error) {
	asked := target + "?from=" + strconv.FormatInt(from, 10)
	nonce := ""

	for attempt := 0; ; attempt++ {
		response, err := a.fetched(ctx, asked, nonce)
		if err != nil {
			return nil, err
		}

		offered := response.Header.Get("DPoP-Nonce")
		if response.StatusCode == http.StatusUnauthorized && attempt == 0 && offered != "" && offered != nonce {
			response.Body.Close()
			nonce = offered

			continue
		}

		return response, nil
	}
}

func pause(ctx context.Context, wait time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(wait):
		return nil
	}
}
