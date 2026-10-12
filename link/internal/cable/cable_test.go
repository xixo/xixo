package cable

import "testing"

func TestDataNamesTheActionFirst(t *testing.T) {
	cases := []struct {
		payload any
		want    string
	}{
		{nil, `{"action":"hello"}`},
		{struct{}{}, `{"action":"hello"}`},
		{map[string]int64{"size": 1 << 60}, `{"action":"hello","size":1152921504606846976}`},
	}

	for _, each := range cases {
		got, err := Data("hello", each.payload)
		if err != nil || got != each.want {
			t.Errorf("Data(%v) = %s, %v", each.payload, got, err)
		}
	}

	if _, err := Data("hello", []int{1}); err == nil {
		t.Error("a list is not a payload")
	}
}

func TestEndpoints(t *testing.T) {
	socket, target, origin, err := Endpoints("https://xixo.example/")
	if err != nil || socket != "wss://xixo.example/cable" || target != "https://xixo.example/cable" || origin != "https://xixo.example" {
		t.Fatalf("%s %s %s %v", socket, target, origin, err)
	}

	socket, _, _, _ = Endpoints("http://xixo.localhost:8180")
	if socket != "ws://xixo.localhost:8180/cable" {
		t.Fatalf("%s", socket)
	}

	if _, _, _, err := Endpoints("ftp://xixo.example"); err == nil {
		t.Fatal("ftp is refused")
	}
}
