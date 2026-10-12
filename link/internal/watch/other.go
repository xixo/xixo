//go:build !linux && !darwin

package watch

const most = 0

func open() (backend, error) {
	return nil, ErrUnsupported
}
