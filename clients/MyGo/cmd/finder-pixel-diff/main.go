package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"image"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"terminal-finder-mygo/internal/visualdiff"
)

type reportItem struct {
	Name string `json:"component"`
	visualdiff.Result
}

func read(path string) (image.Image, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	im, format, e := image.Decode(f)
	if e != nil {
		return nil, e
	}
	if format != "png" {
		return nil, fmt.Errorf("lossless PNG required: %s", path)
	}
	return im, nil
}
func run() (bool, error) {
	reference := flag.String("reference", "", "directory of original component PNGs")
	candidate := flag.String("candidate", "", "directory of MyGo component PNGs")
	output := flag.String("out", "", "report and heatmap directory")
	strict := flag.Bool("require-exact", false, "exit with status 2 if any original pixel differs")
	flag.Parse()
	if *reference == "" || *candidate == "" || *output == "" {
		return false, fmt.Errorf("--reference, --candidate and --out are required")
	}
	if err := os.MkdirAll(*output, 0755); err != nil {
		return false, err
	}
	files, err := filepath.Glob(filepath.Join(*reference, "*.png"))
	if err != nil || len(files) == 0 {
		return false, fmt.Errorf("no reference PNGs")
	}
	items := []reportItem{}
	exact := true
	for _, path := range files {
		name := filepath.Base(path)
		a, e := read(path)
		if e != nil {
			return false, e
		}
		b, e := read(filepath.Join(*candidate, name))
		if e != nil {
			return false, e
		}
		result, e := visualdiff.Compare(a, b)
		if e != nil {
			return false, fmt.Errorf("%s: %w", name, e)
		}
		exact = exact && result.Exact
		items = append(items, reportItem{Name: name, Result: result})
		f, e := os.Create(filepath.Join(*output, name))
		if e != nil {
			return false, e
		}
		e = png.Encode(f, visualdiff.Heatmap(a, b))
		f.Close()
		if e != nil {
			return false, e
		}
		fmt.Printf("%s: exact=%t MAE=%.4f changed=%.2f%%\n", name, result.Exact, result.MeanRGBError, result.ChangedFraction*100)
	}
	data, e := json.MarshalIndent(struct {
		PixelExact bool         `json:"pixelExact"`
		Components []reportItem `json:"components"`
	}{exact, items}, "", "  ")
	if e != nil {
		return false, e
	}
	if e = os.WriteFile(filepath.Join(*output, "report.json"), append(data, '\n'), 0644); e != nil {
		return false, e
	}
	return *strict && !exact, nil
}
func main() {
	different, err := run()
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}
	if different {
		os.Exit(2)
	}
}
