package parts

import (
	"compress/gzip"
	"io"
	"time"
)

func setProbation(held time.Duration) { probation = held }

func gzipWriter(w io.Writer) io.WriteCloser { return gzip.NewWriter(w) }
