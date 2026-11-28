---
name: plex-collections
description: Manage Kometa, which builds the automatic Plex collections (franchises like Harry Potter, genres, trending, streaming, seasonal) in the media-system stack. Use this whenever the user wants to add, remove or change Plex collections or overlays, asks why a collection is missing or wrong, wants Kometa to run now, check whether it worked, read its logs, change its schedule, rotate the Plex token or TMDb key, or bump the Kometa image, even if they only say "collections", "Plex lists" or "Nateflix" without naming Kometa.
---

# Kometa (automatic Plex collections)

Kometa is a scheduled job, not a web app. It reads a YAML config, talks to Plex
and TMDb, and creates or syncs collections. There is no UI: Plex's Collections
tab is where results show up, and the log is where problems show up.

## Where things live

| What | Where |
|---|---|
| Service definition | `stacks/media-system/docker-compose.yml` (service `kometa`) |
| Collection config | `stacks/media-system/kometa/config.yml` (in git, mounted read-only at `/config/config.yml`) |
| Secrets wiring | `komodo/komodo.toml`, media-system stack: `PLEX_TOKEN = [[MEDIA_PLEX_TOKEN]]`, `TMDB_API_KEY = [[MEDIA_TMDB_API_KEY]]` |
| Logs and cache on the host | `/opt/appdata/media-system/kometa/` on docker-main (`logs/meta.log`) |
| Host | docker-main, reached over SSH as `nathan@docker.lan` (`docker-main` is only the Komodo name and does not resolve) |
| Compose project on the host | `media-system`, working dir `/opt/komodo/stacks/media-system/stacks/media-system` |

The config changes through git: edit `config.yml`, open a PR, and Komodo
redeploys after merge (`poll_for_updates = true`). Never edit files on the host
directly; the host copy would be overwritten and the repo would drift.

## Plex libraries

The Plex server is called "Nateflix". Library names in `config.yml` must match
Plex exactly, or Kometa skips that library with an error:

- `Nateflix Movies` (movie)
- `Nateflix TV Shows` (show)
- `Nateflix Documentaries` (movie, kept light: `basic` and `streaming` only, since genre/franchise collections add little here)

If the user mentions a library that isn't in this list, ask for its exact name
(a screenshot of Plex Settings → Libraries works) rather than guessing.

## Changing collections

Collections come from Kometa's built-in "default" files, listed under
`collection_files:` per library:

```yaml
libraries:
  Nateflix Movies:
    collection_files:
      - default: franchise
      - default: genre
```

Default file names are easy to misremember, and a wrong name fails the whole
library at run time. Check the name exists for the pinned Kometa version before
using it (read the version from the `image:` line in the compose file):

```bash
for d in movie show both chart award; do echo "== $d"; curl -s "https://api.github.com/repos/Kometa-Team/Kometa/contents/defaults/$d?ref=v2.5.5" | jq -r '.[].name' | tr '\n' ' '; echo; done
```

Rough map: `movie/` (franchise, seasonal, decade, director, ...) is movie-only,
`show/` (network, franchise, ...) is show-only, `both/` (genre, streaming,
studio, actor, collectionless, universe, ...) and `chart/` (basic, tmdb, imdb,
trakt, letterboxd, tautulli, ...) work for either. `award/` has oscars, emmy,
golden and so on. Per-file options go under `template_variables:`; the defaults
docs at https://kometa.wiki/en/latest/defaults/collections/ list them.

Some defaults need another service configured in `config.yml` first:
`trakt`/`imdb` charts and `tautulli` need their own connection blocks (Trakt
needs an OAuth flow that writes tokens into the config, which doesn't work with
this read-only, git-managed setup without extra work). Say so before adding
one of these rather than adding a file that will fail.

Global behaviour in `settings:` is deliberate:
- `sync_mode: sync` removes items that drop off a list (e.g. no longer trending).
- `minimum_items: 2` with `delete_below_minimum: true` stops single-movie "franchises".

Overlays (4K/HDR badges, ratings on posters) go under `overlay_files:` per
library. They rewrite poster images in Plex, so mention that to the user and
note that `remove_overlays: true` is how to undo them.

### Secrets in the config

Secrets are never written into `config.yml`. A `KOMETA_<NAME>` env var becomes
the placeholder `<<name>>` (lowercase, no underscores: `<<plextoken>>` works,
`<<plex_token>>` does not). To add a new secret: add `KOMETA_X=${X}` to the
compose service, `X = [[MEDIA_X]]` to the media-system `environment` in
`komodo/komodo.toml`, `X=` to `stacks/media-system/.env.defaults`, and have
the user create the Komodo secret variable `MEDIA_X` (UI: Settings →
Variables, tick Secret; or `komodo/scripts/komodo-set-vars.sh`).

The TMDb value is the short v3 **API Key** (32 hex chars), not the long
"API Read Access Token".

## Before committing

```bash
python3 -c "import yaml; yaml.safe_load(open('stacks/media-system/kometa/config.yml'))"
python3 .github/scripts/check_pinned_images.py
(cd stacks/media-system && docker-compose -f docker-compose.yml config --quiet)
```

Missing-variable warnings from `docker-compose config` locally are expected.
Image bumps follow the repo rule in `CLAUDE.md` (tag plus multi-arch index
digest); Dependabot also bumps this image weekly. Prefer a release tag
(`vX.Y.Z`) at least two weeks old over `latest`/`nightly`/`develop`.

## Checking on it (read-only)

These only read state, so they're fine to run without asking:

```bash
# container up?
ssh nathan@docker.lan 'docker ps -a --filter name=^kometa$ --format "{{.Names}} {{.Status}} {{.Image}}"'
# config and secrets reached the container? prints lengths, never values
ssh nathan@docker.lan 'docker exec kometa sh -c "grep -c Nateflix /config/config.yml; for v in KOMETA_PLEXTOKEN KOMETA_TMDBKEY KOMETA_TIMES; do eval x=\\\$\$v; [ -n \"\$x\" ] && echo \"\$v set (\${#x} chars)\" || echo \"\$v EMPTY\"; done"'
# last run
ssh nathan@docker.lan 'tail -n 150 /opt/appdata/media-system/kometa/logs/meta.log'
```

Never print the token or key values (no `env`, no `docker inspect` of the
environment, no `cat .env`): they'd land in the transcript. Kometa logs mask
secrets, but grep out lines mentioning tokens anyway when sharing log output.

Reading the results:
- An empty `logs/` folder just means no run has happened yet. It runs daily at
  `KOMETA_TIMES` (default 04:00, America/Detroit). `docker logs kometa` stays
  quiet while it waits.
- A 0-byte `config.yml` in the host appdata folder is normal; it's the
  bind-mount target, and the real file is mounted over it.
- An error saying a library wasn't found → library name mismatch.
- 401 from Plex → bad or rotated Plex token. 401 from TMDb → wrong TMDb value
  (often the read access token instead of the API key).
- Connection refused to `host.docker.internal:32400` → Plex is down, or the
  `extra_hosts: host-gateway` line was lost (Plex uses host networking).
- In Plex: library → Collections tab. A first run on a large library takes
  10-30 minutes.

## Actions that change live state (ask first)

Per the user's standing rule, merges, deploys and anything that changes a host
wait for an explicit OK in chat. That includes:

- Starting an immediate run (Kometa then edits Plex collections):
  ```bash
  ssh nathan@docker.lan 'docker exec kometa /.venv/bin/python3 /kometa.py --run'
  ```
  Add `--run-libraries "Nateflix Movies"` (pipe-separated for several) to
  limit it to one library, which is much faster when testing a change.
- Restarting or recreating the container, or merging a config PR.

Plex's own "Minimum automatic collection size" setting creates franchise
collections too. If the user sees duplicate franchise collections, that
setting is the likely cause; turning it off is a Plex setting change the user
should make (or approve).

## Getting the keys (when the user needs to rotate them)

- Plex token, on docker-main (have the user run it in their own terminal so the
  value never enters the chat):
  `ssh nathan@docker.lan 'grep -o "PlexOnlineToken=\"[^\"]*\"" "/opt/appdata/media-system/plex/Library/Application Support/Plex Media Server/Preferences.xml"'`
  Or Plex Web: any item → ⋯ → Get Info → View XML → `X-Plex-Token=` in the URL.
- TMDb: themoviedb.org → Settings → API. The form rejects one-line summaries;
  a few sentences on personal, read-only, daily use for organizing a home Plex
  library gets approved.
