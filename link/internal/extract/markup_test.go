package extract

import "testing"

func TestMarkupKeepsHeadingsAndBlocks(t *testing.T) {
	said := Markup("<style>p{}</style><h2>Plan <b>B</b></h2><p>one&amp;two</p><script>x()</script><p>three</p>")

	if said != "## Plan B\n\none&two\nthree" {
		t.Fatalf("%q", said)
	}
}

func TestMarkupDecodesEveryEntity(t *testing.T) {
	said := Markup("<p>Balance&nbsp;carried forward: &pound;1,240.00 &mdash; &#8364;5 &#x41;</p>")

	if said != "Balance carried forward: £1,240.00 — €5 A" {
		t.Fatalf("%q", said)
	}
}
