package visualdiff

import (
	"image"
	"image/color"
	"testing"
)

func TestExactAndSingleChannelError(t *testing.T) {
	a := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	b := image.NewNRGBA(a.Bounds())
	for x := 0; x < 2; x++ {
		a.SetNRGBA(x, 0, color.NRGBA{38, 38, 38, 255})
		b.SetNRGBA(x, 0, color.NRGBA{38, 38, 38, 255})
	}
	got, err := Compare(a, b)
	if err != nil || !got.Exact {
		t.Fatal(got, err)
	}
	b.SetNRGBA(1, 0, color.NRGBA{38, 38, 41, 255})
	got, err = Compare(a, b)
	if err != nil || got.Exact || got.MeanRGBError != .5 || got.ChangedFraction != .5 || got.MaxChannelError != 3 {
		t.Fatal(got, err)
	}
}
func TestSizeMismatchIsNotSilentlyRescaled(t *testing.T) {
	if _, err := Compare(image.NewNRGBA(image.Rect(0, 0, 10, 10)), image.NewNRGBA(image.Rect(0, 0, 20, 20))); err == nil {
		t.Fatal("size mismatch accepted")
	}
}
func TestAlphaAndPixelPositionsAreNotIgnored(t *testing.T) {
	a := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	b := image.NewNRGBA(a.Bounds())
	a.SetNRGBA(0, 0, color.NRGBA{255, 255, 255, 255})
	b.SetNRGBA(1, 0, color.NRGBA{255, 255, 255, 255})
	got, err := Compare(a, b)
	if err != nil || got.Exact || got.ChangedFraction != 1 {
		t.Fatal(got, err)
	}
	b.SetNRGBA(1, 0, color.NRGBA{})
	a.SetNRGBA(0, 0, color.NRGBA{0, 0, 0, 255})
	got, err = Compare(a, b)
	if err != nil || got.Exact || got.MaxAlphaError != 255 {
		t.Fatal(got, err)
	}
}

func TestSixteenBitLowChannelDifferenceCannotPassExact(t *testing.T) {
	a := image.NewNRGBA64(image.Rect(0, 0, 1, 1))
	b := image.NewNRGBA64(a.Bounds())
	a.SetNRGBA64(0, 0, color.NRGBA64{R: 10000, A: 65535})
	b.SetNRGBA64(0, 0, color.NRGBA64{R: 10001, A: 65535})
	got, err := Compare(a, b)
	if err != nil || got.Exact || got.ChangedFraction != 1 || got.MeanRGBError <= 0 {
		t.Fatal(got, err)
	}
}
