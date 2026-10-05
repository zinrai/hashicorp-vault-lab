# Built from this checkout, not pulled as a release: the application reads
# what the agent templates in vault-agent-configs/ render, and both change
# together in this repository.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /vault-lab-app .

# alpine, not scratch: the checks and the documents read what an
# application was handed with docker exec ... cat.
FROM alpine:3.22
COPY --from=build /vault-lab-app /usr/local/bin/vault-lab-app
ENTRYPOINT ["/usr/local/bin/vault-lab-app"]
