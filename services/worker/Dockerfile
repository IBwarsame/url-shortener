# syntax=docker/dockerfile:1

# ---- build: static binary, cross-compiled for the target arch ----
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/worker .

# ---- runtime: distroless, non-root ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/worker /worker
USER nonroot:nonroot
ENTRYPOINT ["/worker"]
