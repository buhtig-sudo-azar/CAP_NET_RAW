FROM alpine:latest

RUN apk add --no-cache gcc musl-dev linux-headers

# Копируем исходник из той же директории, где лежит Dockerfile
COPY sniffer.c /sniffer.c

RUN gcc -o /sniffer /sniffer.c

ENTRYPOINT ["/sniffer"]