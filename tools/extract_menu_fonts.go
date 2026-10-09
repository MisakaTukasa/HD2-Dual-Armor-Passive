// Run from a filediver checkout: go run <this-file> <repo> <game-data> <output-dir>.
// Reads installed assets. Writes only the explicitly supplied local output directory.
// Requires the cached dependencies of github.com/xypwn/filediver; no assets are downloaded.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/xypwn/filediver/stingray"
	"github.com/xypwn/filediver/stingray/unit/material"
)

func hash(s string) stingray.Hash {
	n, err := strconv.ParseUint(s, 16, 64)
	if err != nil {
		panic(err)
	}
	return stingray.Hash{Value: n}
}
func main() {
	if len(os.Args) != 4 {
		panic("Expected repo, game-data, output-dir")
	}
	root, game, out := os.Args[1], os.Args[2], os.Args[3]
	raw, err := os.ReadFile(filepath.Join(root, "data/menu_fonts.json"))
	if err != nil {
		panic(err)
	}
	var cfg map[string]struct {
		Resources []map[string]any `json:"resources"`
	}
	if err = json.Unmarshal(raw, &cfg); err != nil {
		panic(err)
	}
	d, err := stingray.OpenDataDir(context.Background(), game, nil)
	if err != nil {
		panic(err)
	}
	if err = os.MkdirAll(out, 0755); err != nil {
		panic(err)
	}
	rows := []map[string]any{}
	for _, language := range []string{"zh_cn", "zh_tw"} {
		p := cfg[language].Resources[0]
		for _, field := range []string{"font", "material", "atlas"} {
			kind := field
			if kind == "atlas" {
				kind = "texture"
			}
			name := p[field].(string)
			source := name
			if field == "material" {
				source = p["material_source"].(string)
			}
			id := stingray.FileID{Name: hash(source), Type: stingray.Sum(kind)}
			for _, part := range []struct {
				Type          stingray.DataType
				Suffix, Check string
			}{
				{stingray.DataMain, "main", map[string]string{"font": "sha256", "atlas": "atlas_main_sha256"}[field]},
				{stingray.DataGPU, "gpu", "atlas_gpu_sha256"},
			} {
				if part.Type == stingray.DataGPU && field != "atlas" {
					continue
				}
				payload, err := d.Read(id, part.Type)
				if err != nil {
					panic(err)
				}
				sourceSHA := fmt.Sprintf("%x", sha256.Sum256(payload))
				if part.Check != "" && p[part.Check] != sourceSHA {
					panic("Native font/atlas checksum changed: " + source)
				}
				if field == "material" {
					if p["material_source_sha256"] != sourceSHA {
						panic("Native font material checksum changed: " + source)
					}
					// Preserve every shader and setting byte; bind the known static atlas.
					if len(payload) != 448 || binary.LittleEndian.Uint32(payload[64:68]) != 1 ||
						binary.LittleEndian.Uint32(payload[136:140]) != 0x88bac99b {
						panic("Unsupported native font material layout")
					}
					payload = append([]byte(nil), payload...)
					binary.LittleEndian.PutUint64(payload[140:148], hash(p["atlas"].(string)).Value)
					m, err := material.LoadMain(bytes.NewReader(payload))
					if err != nil {
						panic(err)
					}
					if len(m.Textures) != 1 || m.Textures[stingray.ThinHash{Value: 0x88bac99b}] != hash(p["atlas"].(string)) {
						panic("Invalid isolated font material texture binding")
					}
				}
				filename := name + "." + kind + "." + part.Suffix
				if err = os.WriteFile(filepath.Join(out, filename), payload, 0644); err != nil {
					panic(err)
				}
				rows = append(rows, map[string]any{"language": language, "field": field, "name": name, "type": kind,
					"part": part.Suffix, "bytes": len(payload), "source": source, "source_sha256": sourceSHA,
					"sha256": fmt.Sprintf("%x", sha256.Sum256(payload))})
			}
		}
	}
	raw, err = json.MarshalIndent(rows, "", "  ")
	if err != nil {
		panic(err)
	}
	if err = os.WriteFile(filepath.Join(out, "extraction.json"), append(raw, '\n'), 0644); err != nil {
		panic(err)
	}
	fmt.Println("Extracted two primary fonts, two static atlases and two isolated font materials.")
}
