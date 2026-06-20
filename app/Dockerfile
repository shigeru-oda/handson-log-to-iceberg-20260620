# syntax=docker/dockerfile:1

# ---- Stage 1: build ----------------------------------------------------------
# Pin the Go toolchain to match go.mod (go 1.25.x). The builder runs on the
# host's native architecture but cross-compiles a static Linux/amd64 binary so
# the resulting image runs on ECS Fargate (Linux/amd64) regardless of where it
# is built (Req 1.1, 2.1).
FROM golang:1.25 AS build

WORKDIR /src

# Download dependencies first so this layer is cached unless go.mod/go.sum change.
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the module and build a fully static binary.
COPY . .

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

# -trimpath and -ldflags "-s -w" produce a smaller, reproducible binary.
RUN go build -trimpath -ldflags="-s -w" -o /out/log-generator ./cmd/log-generator

# ---- Stage 2: runtime --------------------------------------------------------
# distroless/static is a minimal image (no shell, no package manager) suitable
# for a CGO-disabled static binary. It still ships CA certificates and runs as a
# non-root user by default.
FROM gcr.io/distroless/static:nonroot

# Copy only the compiled binary from the build stage.
COPY --from=build /out/log-generator /usr/local/bin/log-generator

# LOG_INTERVAL_MS is intentionally NOT set here. The ECS task definition injects
# it at runtime (Req 2.3); the app fails fast if it is missing or invalid.
ENTRYPOINT ["/usr/local/bin/log-generator"]
