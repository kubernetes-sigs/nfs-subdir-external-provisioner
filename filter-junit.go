/*
Copyright 2019 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

/*
 * This command filters a JUnit file such that only tests with a name
 * matching a regular expression are passed through. By concatenating
 * multiple input files it is possible to merge them into a single file.
 */
package main

import (
	"encoding/xml"
	"flag"
	"io/ioutil"
	"os"
	"regexp"
)

var (
	output = flag.String("o", "-", "junit file to write, - for stdout")
	tests  = flag.String("t", "", "regular expression matching the test names that are to be included in the output")
)

/*
 * TestSuite represents a JUnit file. Due to how encoding/xml works, we have
 * represent all fields that we want to be passed through. It's therefore
 * not a complete solution, but good enough for Ginkgo + Spyglass.
 */
type TestSuite struct {
	XMLName   string     `xml:"testsuite"`
	TestCases []TestCase `xml:"testcase"`
}

type TestCase struct {
	Name      string     `xml:"name,attr"`
	Time      string     `xml:"time,attr"`
	SystemOut string     `xml:"system-out,omitempty"`
	Failure   string     `xml:"failure,omitempty"`
	Skipped   SkipReason `xml:"skipped,omitempty"`
}

// SkipReason deals with the special <skipped></skipped>:
// if present, we must re-encode it, even if empty.
type SkipReason string

func (s *SkipReason) UnmarshalText(text []byte) error {
	*s = SkipReason(text)
	if *s == "" {
		*s = " "
	}
	return nil
}

func (s SkipReason) MarshalText() ([]byte, error) {
	if s == " " {
		return []byte{}, nil
	}
	return []byte(s), nil
}

func main() {
	var junit TestSuite
	var data []byte

	flag.Parse()

	re := regexp.MustCompile(*tests)

	// Read all input files.
	for _, input := range flag.Args() {
		if input == "-" {
			if _, err := os.Stdin.Read(data); err != nil {
				panic(err)
			}
		} else {
			var err error
			data, err = ioutil.ReadFile(input)
			if err != nil {
				panic(err)
			}
		}
		if err := xml.Unmarshal(data, &junit); err != nil {
			panic(err)
		}
	}

	// Keep only matching testcases. Testcases skipped in all test runs are only stored once.
	filtered := map[string]TestCase{}
	for _, testcase := range junit.TestCases {
		if !re.MatchString(testcase.Name) {
			continue
		}
		entry, ok := filtered[testcase.Name]
		if !ok || // not present yet
			entry.Skipped != "" && testcase.Skipped == "" { // replaced skipped test with real test run
			filtered[testcase.Name] = testcase
		}
	}
	junit.TestCases = nil
	for _, testcase := range filtered {
		junit.TestCases = append(junit.TestCases, testcase)
	}

	// Re-encode.
	data, err := xml.MarshalIndent(junit, "", "  ")
	if err != nil {
		panic(err)
	}

	// Write to output.
	if *output == "-" {
		if _, err := os.Stdout.Write(data); err != nil {
			panic(err)
		}
	} else {
		if err := ioutil.WriteFile(*output, data, 0644); err != nil {
			panic(err)
		}
	}
}
