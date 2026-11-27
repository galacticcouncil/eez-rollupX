FROM busybox:1.37.0-musl@sha256:f6a95d611e0a8780fabdb2aec43e31275b2720dfefa3e41b16835bfc42454478 AS tools
FROM ethpandaops/reth-rbuilder@sha256:916ba84da2690e3e368f57da5b0c73bfd919b452de8b95f64895846e0f3a8308
COPY --from=tools /bin/busybox /busybox
