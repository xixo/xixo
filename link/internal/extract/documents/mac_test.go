package documents

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPageOutlineStartsEachBookmarkAtItsPage(t *testing.T) {
	var read macPages
	if err := json.Unmarshal([]byte(`{"pages": ["\n Cover", "Roof\nfelt", "Walls"],
		"outline": [{"name": "Roof", "page": 2}, {"name": "Walls", "page": 3}, {"name": "Gone", "page": 9}]}`), &read); err != nil {
		t.Fatal(err)
	}

	text := strings.TrimSpace(strings.Join(read.Pages, pageBreak))
	sections := PageOutline(read, text, MaxText)

	if len(sections) != 2 || sections[0].From != strings.Index(text, "Roof") || sections[1].From != strings.Index(text, "Walls") {
		t.Fatalf("sections %+v in %q", sections, text)
	}

	if cut := PageOutline(read, text, 8); len(cut) != 1 {
		t.Fatalf("a bookmark past the cut was kept: %+v", cut)
	}
}

func TestMacExtractorsShareTheirNamesWithTheProgramOnes(t *testing.T) {
	if (MacPdf{}).Name() != (Pdf{}).Name() || (MacImage{}).Name() != (Image{}).Name() || (MacDoc{}).Name() != (Doc{}).Name() {
		t.Fatal("a mac extractor reports a name the server does not route on")
	}

	if !(MacDoc{}).Handles("text/rtf", "a.rtf") || !(MacDoc{}).Handles(Docx, "a.docx") || (MacDoc{}).Handles("text/plain", "a.txt") {
		t.Fatal("the mac doc extractor handles the wrong types")
	}
}
