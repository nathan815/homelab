# Repo rules

## Pin every container image

Every `image:` in `stacks/*/`, compose templates, and every Dockerfile `FROM` must include a digest, keeping the tag:

    image: grafana/grafana:11.2.0@sha256:<digest>

- Always use an explicit version tag, never bare or `:latest`. Only images that publish no versioned tags (`dev`/`main` rolling builds) may use that tag.
- Resolve the digest with `docker buildx imagetools inspect <image>:<tag>` (use the top-level `Digest:`, the multi-arch index).
- Exceptions: refs built from variables (e.g. `${IMAGE_TAG}`).
- `.github/scripts/check_pinned_images.py` enforces this in CI; run it before committing.

Dependabot (`.github/dependabot.yml`) opens weekly grouped PRs that bump these pins. It can't see `ansible/roles/zigbee2mqtt/templates/docker-compose.yml.j2` or `.woodpecker/deploy.yaml`; update those by hand.
