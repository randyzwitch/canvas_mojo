// Check local links, images, and HTML fragments in the generated Hugo site.
// Hugo emits quoted attributes, so these scans need only the Go standard
// library already available in the docs environment. External URLs are skipped.
package main

import (
	"fmt"
	"html"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var tags = regexp.MustCompile(`<[^>]+>`)
var attributes = regexp.MustCompile(`\b(href|src|id)\s*=\s*(?:"([^"]*)"|'([^']*)')`)

type page struct {
	file string
	url  *url.URL
	ids  map[string]bool
	refs []string
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: check_doc_links SITE_DIRECTORY BASE_URL")
		os.Exit(2)
	}
	root, err := filepath.Abs(os.Args[1])
	check(err)
	base, err := url.Parse(os.Args[2])
	check(err)
	pages := map[string]page{}
	err = filepath.WalkDir(root, func(file string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(file, ".html") {
			return err
		}
		data, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, file)
		if err != nil {
			return err
		}
		location := filepath.ToSlash(rel)
		location = strings.TrimSuffix(location, "index.html")
		p := page{file: rel, url: base.ResolveReference(&url.URL{Path: location}), ids: map[string]bool{}}
		for _, tag := range tags.FindAllString(string(data), -1) {
			for _, attr := range attributes.FindAllStringSubmatch(tag, -1) {
				value := html.UnescapeString(attr[2] + attr[3])
				if attr[1] == "id" {
					p.ids[value] = true
				} else {
					p.refs = append(p.refs, value)
				}
			}
		}
		pages[file] = p
		return nil
	})
	check(err)
	if len(pages) == 0 {
		check(fmt.Errorf("no HTML pages in %s; build the site first", root))
	}
	failures, checked := 0, 0
	for _, p := range pages {
		for _, ref := range p.refs {
			target, err := p.url.Parse(ref)
			if err != nil {
				fmt.Printf("%s: invalid URL %q: %v\n", p.file, ref, err)
				failures++
				continue
			}
			if target.Scheme != base.Scheme || target.Host != base.Host {
				continue
			}
			if !strings.HasPrefix(target.Path, base.Path) {
				fmt.Printf("%s: link outside the documentation base path %q\n", p.file, ref)
				failures++
				continue
			}
			checked++
			file := filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(target.Path, base.Path)))
			info, err := os.Stat(file)
			if err == nil && info.IsDir() {
				file = filepath.Join(file, "index.html")
				_, err = os.Stat(file)
			}
			if err != nil {
				fmt.Printf("%s: missing target %q\n", p.file, ref)
				failures++
				continue
			}
			if dest, ok := pages[file]; ok && target.Fragment != "" && !dest.ids[target.Fragment] {
				fmt.Printf("%s: missing anchor %q\n", p.file, ref)
				failures++
			}
		}
	}
	if failures > 0 {
		check(fmt.Errorf("%d broken local documentation links", failures))
	}
	fmt.Printf("Checked %d local references across %d HTML pages.\n", checked, len(pages))
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
