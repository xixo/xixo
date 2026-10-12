package plain

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane Pelican\r\nN:Pelican;Jane;;;\r\nORG:Estuary Birds Ltd.\r\n" +
	"TITLE:Chief Wader\r\nitem1.EMAIL;TYPE=INTERNET;TYPE=WORK:jane@estuary.example\r\nTEL;TYPE=CELL:+44 7700 900000\r\n" +
	"ADR;TYPE=WORK:;;Pelican House\\, Unit 3\\; rear;Poole;Dorset;BH15;England\r\n" +
	"NOTE:Prefers to be contacted about anything at all to do with the tide\r\n  tables\\, especially in winter.\r\nEND:VCARD\r\n"

const event = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:pelicans-1\nDTSTART:20270830T120000Z\n" +
	"SUMMARY:Lunch with the pelicans\\, then the tide tables\\; briefly\nLOCATION:1 Mudflat Lane\nEND:VEVENT\nEND:VCALENDAR\n"

func kept(t *testing.T, name, body string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	return path
}

func firstRecord(t *testing.T, result any) map[string]any {
	t.Helper()

	encoded, _ := json.Marshal(result)
	held := []map[string]any{}
	if err := json.Unmarshal(encoded, &held); err != nil || len(held) == 0 {
		t.Fatalf("not a list of records: %s", encoded)
	}

	return held[0]
}

func TestACardIsUnfoldedUngroupedAndUnescaped(t *testing.T) {
	out := run(t, kept(t, "jane.vcf", card), "text/vcard")
	contact := firstRecord(t, out.Steps["contacts"].Result)

	want := map[string]any{
		"fn": "Jane Pelican", "name": "Pelican Jane", "org": "Estuary Birds Ltd.",
		"email": []any{"jane@estuary.example"}, "tel": []any{"+44 7700 900000"},
		"adr": []any{"Pelican House, Unit 3; rear Poole Dorset BH15 England"},
	}

	for key, value := range want {
		got, _ := json.Marshal(contact[key])
		expected, _ := json.Marshal(value)

		if string(got) != string(expected) {
			t.Errorf("%s: got %s, want %s", key, got, expected)
		}
	}

	if note, _ := contact["note"].(string); !strings.Contains(note, "especially in winter.") {
		t.Errorf("the folded note was cut: %q", note)
	}

	if !strings.Contains(text(out), "jane@estuary.example") {
		t.Errorf("text %q", text(out))
	}
}

func TestAnEscapedCommaOrSemicolonSurvivesInAnEvent(t *testing.T) {
	out := run(t, kept(t, "lunch.ics", event), "text/calendar")

	if summary := firstRecord(t, out.Steps["events"].Result)["summary"]; summary != "Lunch with the pelicans, then the tide tables; briefly" {
		t.Errorf("summary %q", summary)
	}
}
