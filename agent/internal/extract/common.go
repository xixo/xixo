package extract

import "context"

func Common(ctx context.Context, in Input, out *Output) error {
	if Describable(in.MIME) && !in.Skipped("metadata") {
		if found, err := ReadMetadata(ctx, in.Run, in.Path); err != nil {
			out.Fail("metadata", err)
		} else {
			out.Set("metadata", found)
		}
	}

	if Thumbnailable(in.MIME) && !in.Skipped("derived") {
		files, err := Derive(ctx, in)
		if err != nil {
			out.Fail("derived", err)

			return nil
		}

		named := map[string]string{}
		for _, file := range files {
			named[file.Role] = file.Name
			out.Attach(file)
		}

		out.Set("derived", named)
	}

	return nil
}
