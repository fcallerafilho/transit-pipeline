# Same multi-stage pattern as the ingester: compile a static binary, ship it on a
# tiny distroless base (DESIGN §4.2). Single-arch for local; multi-arch via `make buildx`.
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /readapi .

FROM gcr.io/distroless/static-debian12
COPY --from=build /readapi /readapi
EXPOSE 8080
ENTRYPOINT ["/readapi"]
