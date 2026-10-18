// Package visualdiff compares original pixels. It never aligns, resizes, blurs,
// thresholds, or masks its inputs, and never calls a near match an exact match.
package visualdiff

import (
	"fmt"
	"image"
	"image/color"
	"math"
)

type Result struct {
	Width           int     `json:"width"`
	Height          int     `json:"height"`
	Exact           bool    `json:"pixelExact"`
	MeanRGBError    float64 `json:"meanRGBError"`
	RMSE            float64 `json:"rgbRMSE"`
	MaxChannelError float64 `json:"maxChannelError"`
	MaxAlphaError   float64 `json:"maxAlphaError"`
	ChangedFraction float64 `json:"changedPixelFraction"`
}

func delta(a, b uint16) uint16 {
	if a > b {
		return a - b
	}
	return b - a
}
func Compare(a, b image.Image) (Result, error) {
	ab, bb := a.Bounds(), b.Bounds()
	if ab.Dx() != bb.Dx() || ab.Dy() != bb.Dy() || ab.Empty() {
		return Result{}, fmt.Errorf("pixel dimensions must match and be nonempty: %v versus %v", ab, bb)
	}
	r := Result{Width: ab.Dx(), Height: ab.Dy(), Exact: true}
	var sum, squares, changed uint64
	for y := 0; y < ab.Dy(); y++ {
		for x := 0; x < ab.Dx(); x++ {
			av := color.NRGBA64Model.Convert(a.At(ab.Min.X+x, ab.Min.Y+y)).(color.NRGBA64)
			bv := color.NRGBA64Model.Convert(b.At(bb.Min.X+x, bb.Min.Y+y)).(color.NRGBA64)
			dr, dg, db, da := delta(av.R, bv.R), delta(av.G, bv.G), delta(av.B, bv.B), delta(av.A, bv.A)
			sum += uint64(dr) + uint64(dg) + uint64(db)
			squares += uint64(dr)*uint64(dr) + uint64(dg)*uint64(dg) + uint64(db)*uint64(db)
			r.MaxChannelError = max(r.MaxChannelError, float64(dr)/257, float64(dg)/257, float64(db)/257)
			r.MaxAlphaError = max(r.MaxAlphaError, float64(da)/257)
			if dr|dg|db|da != 0 {
				changed++
			}
		}
	}
	n := float64(ab.Dx() * ab.Dy())
	r.MeanRGBError = float64(sum) / (n * 3 * 257)
	r.RMSE = math.Sqrt(float64(squares)/(n*3)) / 257
	r.ChangedFraction = float64(changed) / n
	r.Exact = changed == 0
	return r, nil
}

// Heatmap is an analytic output, never an altered input or the rendered UI.
func Heatmap(a, b image.Image) *image.NRGBA {
	out := image.NewNRGBA(image.Rect(0, 0, a.Bounds().Dx(), a.Bounds().Dy()))
	for y := 0; y < out.Bounds().Dy(); y++ {
		for x := 0; x < out.Bounds().Dx(); x++ {
			av := color.NRGBA64Model.Convert(a.At(x+a.Bounds().Min.X, y+a.Bounds().Min.Y)).(color.NRGBA64)
			bv := color.NRGBA64Model.Convert(b.At(x+b.Bounds().Min.X, y+b.Bounds().Min.Y)).(color.NRGBA64)
			d := max(delta(av.R, bv.R), delta(av.G, bv.G), delta(av.B, bv.B), delta(av.A, bv.A))
			out.SetNRGBA(x, y, color.NRGBA{R: uint8(min(255, int(d)*6/257)), G: uint8(min(255, int(d)*2/257)), A: 255})
		}
	}
	return out
}
