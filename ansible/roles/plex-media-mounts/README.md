# plex-media-mounts

Mounts the media drives at `/mnt/disk1` (2TB) and `/mnt/disk2` (4TB) by UUID and pools them with
mergerfs at `/media/plexmedia01`, the only path containers use.

## Policy: `mspmfs`

Tested 2026-10-12 with [files/policy-trial.sh](files/policy-trial.sh) (mergerfs 2.40.2). It uses two
tiny loop images, never the real drives. a = old nearly-full drive, b = new drive.

| Test | `epmfs` | `mspmfs` |
|---|---|---|
| New show | b | b |
| Existing show, a has room | a | a |
| New top-level folder | b | b |
| Existing show, a below `minfreespace` | **ENOSPC, import fails** | **falls back to b** |
| File bigger than a's free space | moved to b | moved to b |

`mspmfs` wins on the fourth row.

## Notes

- Folders that exist on only one drive pull new content there, so `downloads/{tv,movies}` are
  created on both drives.
- No redundancy: losing a drive loses the shows on it.
- First run: stop the media stack and `umount /media/plexmedia01` first; the role refuses to run
  while a plain disk is mounted there. Roll back by remounting the 2TB at the old path.
