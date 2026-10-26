package main

import "testing"

func TestTallyCountsOnlyWhileOnAndEmptiesOnTake(t *testing.T) {
	tl := &domainTally{counts: map[string]*[2]uint32{}}
	tl.record("a.example", false)
	if got := tl.take(); len(got) != 0 {
		t.Fatalf("counted while off: %v", got)
	}
	tl.enable(true)
	tl.record("a.example", false)
	tl.record("a.example", false)
	tl.record("ads.example", true)
	got := tl.take()
	if len(got) != 2 || got[0].Name != "a.example" || got[0].Allowed != 2 || got[1].Name != "ads.example" || got[1].Blocked != 1 {
		t.Fatalf("unexpected counts: %v", got)
	}
	if again := tl.take(); len(again) != 0 {
		t.Fatalf("take must empty the tally: %v", again)
	}
}

func TestTallyOffDiscardsAndCapsDistinctNames(t *testing.T) {
	tl := &domainTally{counts: map[string]*[2]uint32{}}
	tl.enable(true)
	tl.record("x.example", true)
	tl.enable(false)
	tl.enable(true)
	if got := tl.take(); len(got) != 0 {
		t.Fatalf("switching off must discard: %v", got)
	}
	for i := 0; i < tallyMaxNames+50; i++ {
		tl.record("n"+string(rune('a'+i%26))+string(rune('a'+(i/26)%26))+string(rune('a'+(i/676)%26))+".example", false)
	}
	total := uint32(0)
	for _, c := range tl.take() {
		total += c.Allowed
	}
	if total != uint32(tallyMaxNames+50) {
		t.Fatalf("every lookup must be counted, directly or under other; got %d", total)
	}
	tl.record("", true)
	if got := tl.take(); len(got) != 0 {
		t.Fatalf("an empty name must not be counted: %v", got)
	}
}
