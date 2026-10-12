//go:build !darwin

package extract

func Sandbox() (Confiner, error) {
	return nil, ErrNoSandbox
}
