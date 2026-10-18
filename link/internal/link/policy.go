package link

func (a *Link) lent() error {
	if !a.Lend {
		return ErrNotLent
	}

	return nil
}
