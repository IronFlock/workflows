# Minimal image for the release workflow's dry run: a RUN step proves the
# build executes natively on each platform's runner, and the VERSION build
# argument proves that {tag} in build-args became the release tag.
FROM alpine:3.24
ARG VERSION
RUN case "$VERSION" in v[0-9]*) ;; *) echo "VERSION='$VERSION': {tag} was not replaced" >&2; exit 1 ;; esac
RUN uname -m > /arch
USER 65534:65534
CMD ["cat", "/arch"]
