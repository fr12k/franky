//go:generate sh -c "if [ ! -f go.mod ]; then echo 'Initializing go.mod...'; go mod init .containifyci; else echo 'go.mod already exists. Skipping initialization.'; fi"
//go:generate go get github.com/containifyci/engine-ci/protos2
//go:generate go get github.com/containifyci/engine-ci/client
//go:generate go mod tidy

package main

import (
	"os"

	"github.com/containifyci/engine-ci/client/pkg/build"
	"github.com/containifyci/engine-ci/protos2"
)

func main() {
	os.Chdir("../")
	// Static fallback configuration
	opts := build.NewServiceBuild("franky", protos2.BuildType_Zig)
	opts.Verbose = false
	opts.Folder = "./"
	opts.Image = ""
	opts.Properties = map[string]*build.ListValue{
		"goreleaser": build.NewList("true"),
		"optimize":   build.NewList("ReleaseFast"),
	}
	// v3.2 — the agent_memory package embeds SQLite (FTS5 + relational
	// tables via sqlite3 C symbols). The default engine-ci Zig image
	// (containifyci/zig-3.24) is Alpine-based and doesn't ship
	// libsqlite3, so `zig build` fails at link time with "unable to find
	// dynamic system library 'sqlite3'". We override the build-stage
	// Dockerfile to install sqlite-dev from Alpine's apk repo.
	opts.ContainerFiles = map[string]*protos2.ContainerFile{
		"build": sqliteDockerfile(),
	}
	//TODO: adjust the registry to your own container registry
	opts.Registry = "containifyci"
	build.Build(opts)
}

// sqliteDockerfile returns a Dockerfile that mirrors the default
// engine-ci Zig image (Alpine 3.24 + Zig 0.17.0-dev.1422+e863bf3be)
// but adds sqlite-dev so `linkSystemLibrary("sqlite3")` resolves at
// build time. We rebuild from scratch rather than FROM the pre-built
// containifyci/zig-3.24 image because the latter may not be available
// as a stable :latest tag in all environments.
func sqliteDockerfile() *protos2.ContainerFile {
	return &protos2.ContainerFile{
		Name: "zig-sqlite",
		Content: `FROM alpine:3.24
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG ZIG_VERSION=0.17.0-dev.1422+e863bf3be

RUN apk add --no-cache curl xz sqlite-dev && \
  case "$TARGETPLATFORM" in \
  linux/amd64) ZIG_ARCH=x86_64 ;; \
  linux/arm64) ZIG_ARCH=aarch64 ;; \
  *) echo "Unsupported platform: $TARGETPLATFORM" && exit 1 ;; \
  esac && \
  curl -L https://ziglang.org/builds/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz \
  | tar -xJ -C /usr/local && \
  ln -s /usr/local/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /app

# Verify Zig installation
RUN zig version
`,
	}
}
