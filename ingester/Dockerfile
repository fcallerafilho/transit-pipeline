# Multi-stage build: compile a static binary in the full Go image, then copy just
# that binary into a tiny distroless base. Result is a small image (~10-15 MB) with
# no shell and minimal CVE surface — DESIGN §4.2's "deployment shape" argument made
# concrete. Single-arch for 1a; multi-arch buildx is step 1b.
FROM golang:1.27 AS build
WORKDIR /src

# Copy go.mod/go.sum first and download deps so this layer stays cached unless the
# dependency set changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO_ENABLED=0 produces a fully static binary that runs on the empty distroless base.
RUN CGO_ENABLED=0 go build -o /ingester .

FROM gcr.io/distroless/static-debian12
COPY --from=build /ingester /ingester
ENTRYPOINT ["/ingester"]
