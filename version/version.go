/*
Copyright 2026 The Kubernetes Authors.

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

package version

import (
	"fmt"
	"os"
	"runtime"
	"strconv"

	"github.com/fatih/color"
	"github.com/jedib0t/go-pretty/table"
	"github.com/jedib0t/go-pretty/text"
)

// These are set during build time via -ldflags
var (
	Version   = "latest"
	GitCommit = "N/A"
	BuildDate = "N/A"
	Group     = "k8s.io"
	Author    = "Kubernetes"
)

// Info holds the version information of the driver
type Info struct {
	Group        string `json:"Group"`
	Author       string `json:"Author"`
	Version      string `json:"Version"`
	GitCommit    string `json:"Git Commit"`
	BuildDate    string `json:"Build Date"`
	GoVersion    string `json:"Go Version"`
	Compiler     string `json:"Compiler"`
	Platform     string `json:"Platform"`
	KubeVersion  string `json:"KubernetesVersion"`
	RuntimeCores int    `json:"RuntimeCores"`
	TotalMem     int    `json:"TotalMem"`
}

func GetVersion() Info {
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	return Info{
		Group:        Group,
		Author:       Author,
		Version:      Version,
		GitCommit:    GitCommit,
		BuildDate:    BuildDate,
		GoVersion:    runtime.Version(),
		Compiler:     runtime.Compiler,
		Platform:     fmt.Sprintf("%s/%s", runtime.GOOS, runtime.GOARCH),
		RuntimeCores: runtime.GOMAXPROCS(0),
		TotalMem:     int(memStats.TotalAlloc / 1024),
	}
}

var (
	Yellow       = color.New(color.FgHiYellow, color.Bold).SprintFunc()
	YellowItalic = color.New(color.FgHiYellow, color.Bold, color.Italic).SprintFunc()
	Green        = color.New(color.FgHiGreen, color.Bold).SprintFunc()
	Blue         = color.New(color.FgHiBlue, color.Bold).SprintFunc()
	Cyan         = color.New(color.FgCyan, color.Bold, color.Underline).SprintFunc()
	Red          = color.New(color.FgHiRed, color.Bold).SprintFunc()
	White        = color.New(color.FgWhite).SprintFunc()
	WhiteBold    = color.New(color.FgWhite, color.Bold).SprintFunc()
	forceDetail  = "yaml"
)

// Print the version information.
func Print() {
	v := GetVersion()
	t := table.NewWriter()
	t.SetOutputMirror(os.Stdout)

	t.AppendHeader(table.Row{
		"Group", "Author", "Version", "Git Commit", "Build Date",
		"Go Version", "Compiler", "Platform", "Runtime Cores", "Total Memory",
	})

	t.AppendRow([]interface{}{
		v.Group, v.Author, v.Version, v.GitCommit, v.BuildDate,
		v.GoVersion, v.Compiler, v.Platform,
		strconv.Itoa(v.RuntimeCores) + " cores",
		strconv.Itoa(v.TotalMem) + " KB",
	})

	t.SetStyle(table.StyleDefault)
	t.Style().Format.Header = text.FormatUpper
	t.Style().Color.Header = text.Colors{text.FgHiBlue}
	t.Style().Options.SeparateRows = true

	t.Render()
}

func Term() string {
	return fmt.Sprint(`
╭━╮╱╭╮╭━╮╱╱╱╱╱╭━━━╮╱╱╭╮╱╱╱╭╮╱╱╱╱╭━━━╮╱╱╭╮╱╱╱╱╱╱╱╱╱╱╱╭╮╱╱╭━━━╮
┃┃╰╮┃┃┃╭╯╱╱╱╱╱┃╭━╮┃╱╱┃┃╱╱╱┃┃╱╱╱╱┃╭━━╯╱╭╯╰╮╱╱╱╱╱╱╱╱╱╱┃┃╱╱┃╭━╮┃
┃╭╮╰╯┣╯╰┳━━╮╱╱┃╰━━┳╮╭┫╰━┳━╯┣┳━╮╱┃╰━━┳╮┣╮╭╋━━┳━┳━╮╭━━┫┃╱╱┃╰━╯┣━┳━━┳╮╭┳┳━━┳┳━━┳━╮╭━━┳━╮
┃┃╰╮┃┣╮╭┫━━╋━━╋━━╮┃┃┃┃╭╮┃╭╮┣┫╭┻━┫╭━━┻╋╋┫┃┃┃━┫╭┫╭╮┫╭╮┃┣━━┫╭━━┫╭┫╭╮┃╰╯┣┫━━╋┫╭╮┃╭╮┫┃━┫╭╯
┃┃╱┃┃┃┃┃┣━━┣━━┫╰━╯┃╰╯┃╰╯┃╰╯┃┃┣━━┫╰━━┳╋╋┫╰┫┃━┫┃┃┃┃┃╭╮┃╰┳━┫┃╱╱┃┃┃╰╯┣╮╭┫┣━━┃┃╰╯┃┃┃┃┃━┫┃
╰╯╱╰━╯╰╯╰━━╯╱╱╰━━━┻━━┻━━┻━━┻┻╯╱╱╰━━━┻╯╰┻━┻━━┻╯╰╯╰┻╯╰┻━╯╱╰╯╱╱╰╯╰━━╯╰╯╰┻━━┻┻━━┻╯╰┻━━┻╯
`)
}
