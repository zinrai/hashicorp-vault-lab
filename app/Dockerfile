FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -o /out/vault-lab-app .

FROM alpine:3.20
COPY --from=builder /out/vault-lab-app /usr/local/bin/vault-lab-app
ENTRYPOINT ["/usr/local/bin/vault-lab-app"]
