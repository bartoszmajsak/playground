FROM golang:1.19-alpine3.17 AS builder

WORKDIR /app
COPY . .

RUN go build -o http-echo

FROM alpine:3.17
COPY --from=builder /app/http-echo /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/http-echo"]