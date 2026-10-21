# Minimal image for the release workflow's dry run: a RUN step proves the
# build executes natively on each platform's runner.
FROM alpine:3.24
RUN uname -m > /arch
USER 65534:65534
CMD ["cat", "/arch"]
