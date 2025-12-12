FROM alpine:latest
RUN apk add --no-cache gcc musl-dev
WORKDIR /app
COPY c2_client.c .
RUN gcc -Os -o c2_client c2_client.c
CMD ["./c2_client"]
