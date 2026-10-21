# Planted for the harness self-test: outdated base image, root user, a fake key
# baked into the image. Never build this for anything else.
FROM alpine:3.12
COPY config.env /app/config.env
USER root
CMD ["cat", "/app/config.env"]
