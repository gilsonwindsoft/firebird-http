# syntax=docker/dockerfile:1
FROM golang:1.27-trixie AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends firebird-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=1 go vet ./... \
 && CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/fbhttp-gateway ./cmd/fbhttp-gateway

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libfbclient2 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home fbhttp
COPY --from=build /out/fbhttp-gateway /usr/local/bin/fbhttp-gateway
USER fbhttp
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD ["fbhttp-gateway", "-healthcheck"]
ENTRYPOINT ["fbhttp-gateway"]
