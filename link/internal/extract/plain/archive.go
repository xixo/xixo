package plain

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
)

const (
	MostInflated   = 1 << 30
	endRecord      = 22
	endSearched    = endRecord + 65_535
	centralRecord  = 46
	locatorRecord  = 20
	zip64EndRecord = 56
)

var (
	errNoCentral = errors.New("no zip central directory was found")
	errInflated  = errors.New("the archive unpacks past what the listing reads")
)

func zipped(ctx context.Context, name string) ([]string, error) {
	opened, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer opened.Close()

	info, err := opened.Stat()
	if err != nil {
		return nil, err
	}

	start, size, err := central(opened, info.Size())
	if err != nil {
		return nil, err
	}

	reader := bufio.NewReader(io.NewSectionReader(opened, start, size))
	header := make([]byte, centralRecord)
	listed := []string{}

	for len(listed) < MostListed {
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		if _, err := io.ReadFull(reader, header); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}

			return nil, err
		}

		if binary.LittleEndian.Uint32(header) != 0x02014b50 {
			break
		}

		named := int(binary.LittleEndian.Uint16(header[28:]))
		extra := int64(binary.LittleEndian.Uint16(header[30:])) + int64(binary.LittleEndian.Uint16(header[32:]))

		held := make([]byte, named)
		if _, err := io.ReadFull(reader, held); err != nil {
			return nil, err
		}

		if _, err := reader.Discard(int(extra)); err != nil {
			return nil, err
		}

		listed = append(listed, string(held))
	}

	return listed, nil
}

func central(opened io.ReaderAt, size int64) (int64, int64, error) {
	searched := min(size, endSearched)
	tail := make([]byte, searched)

	if _, err := opened.ReadAt(tail, size-searched); err != nil && !errors.Is(err, io.EOF) {
		return 0, 0, err
	}

	at := -1
	for i := len(tail) - endRecord; i >= 0; i-- {
		if binary.LittleEndian.Uint32(tail[i:]) == 0x06054b50 {
			at = i

			break
		}
	}

	if at < 0 {
		return 0, 0, errNoCentral
	}

	record := tail[at:]
	end := size - searched + int64(at)
	length := int64(binary.LittleEndian.Uint32(record[12:]))
	start := int64(binary.LittleEndian.Uint32(record[16:]))

	if length == 0xffffffff || start == 0xffffffff {
		return central64(opened, end)
	}

	if start+length > end || !centralAt(opened, start) {
		start = end - length
	}

	if start < 0 || length < 0 {
		return 0, 0, errNoCentral
	}

	return start, length, nil
}

func centralAt(opened io.ReaderAt, at int64) bool {
	signature := make([]byte, 4)
	if _, err := opened.ReadAt(signature, at); err != nil {
		return false
	}

	return binary.LittleEndian.Uint32(signature) == 0x02014b50
}

func central64(opened io.ReaderAt, end int64) (int64, int64, error) {
	if end < locatorRecord {
		return 0, 0, errNoCentral
	}

	locator := make([]byte, locatorRecord)
	if _, err := opened.ReadAt(locator, end-locatorRecord); err != nil {
		return 0, 0, err
	}

	if binary.LittleEndian.Uint32(locator) != 0x07064b50 {
		return 0, 0, errNoCentral
	}

	at := int64(binary.LittleEndian.Uint64(locator[8:]))
	if at < 0 || at > end {
		return 0, 0, errNoCentral
	}

	record := make([]byte, zip64EndRecord)
	if _, err := opened.ReadAt(record, at); err != nil {
		return 0, 0, err
	}

	if binary.LittleEndian.Uint32(record) != 0x06064b50 {
		return 0, 0, errNoCentral
	}

	length := int64(binary.LittleEndian.Uint64(record[40:]))
	start := int64(binary.LittleEndian.Uint64(record[48:]))

	if start < 0 || length < 0 || start > at || length > at-start {
		return 0, 0, errNoCentral
	}

	return start, length, nil
}

type bounded struct {
	ctx  context.Context
	from io.Reader
	left int64
}

func (b *bounded) Read(p []byte) (int, error) {
	if err := b.ctx.Err(); err != nil {
		return 0, err
	}

	if b.left <= 0 {
		return 0, errInflated
	}

	if int64(len(p)) > b.left {
		p = p[:b.left]
	}

	count, err := b.from.Read(p)
	b.left -= int64(count)

	return count, err
}
