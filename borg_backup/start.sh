#!/usr/bin/env bashio
export BORG_REPO="ssh://$(bashio::config 'user')@$(bashio::config 'host'):$(bashio::config 'port')/$(bashio::config 'path')"
export BORG_PASSPHRASE="$(bashio::config 'passphrase')"
export BORG_BASE_DIR="/data"
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK="yes"
export BORG_RSH="ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/data/known_hosts"

tmpdir=$(mktemp -d /backup/hassio-borg-XXXXXXXX)
PUBLIC_KEY=`cat ~/.ssh/id_ed25519.pub`

trap 'rm -rf "$tmpdir"' EXIT

bashio::log.info "A public/private key pair was generated for you."
bashio::log.notice "Please use this public key on the backup server:"
bashio::log.notice "${PUBLIC_KEY}"

if [ ! -f /data/known_hosts ]; then
   bashio::log.info "Running for the first time, acquiring host key and storing it in /data/known_hosts."
   ssh-keyscan -p $(bashio::config 'port') "$(bashio::config 'host')" > /data/known_hosts \
     || bashio::exit.nok "Could not acquire host key from backup server."
fi

bashio::log.info 'Trying to initialize the Borg repository.'
/usr/bin/borg init -e "$(bashio::config 'encryption')" || true
/usr/bin/borg info || bashio::exit.nok "Borg repository is not readable."

if [ "$(date +%u)" = 7 ]; then
  bashio::log.info 'Checking archive integrity. (Today is Sunday.)'
  /usr/bin/borg check \
    || bashio::exit.nok "Could not check archive integrity."
fi

for i in /backup/*.tar; do
  backup_info="$i: $(tar xf "$i" ./backup.json -O 2> /dev/null | jq -r '[.name, .date] | join(" | ")' || true)"
  bashio::log.info "Backing up $backup_info"
done

if [ "$(bashio::config 'deduplicate_archives')" ]; then
  for i in /backup/*.tar; do
    archive_name=$(tar xf "$i" ./backup.json -O | jq -r '[.name, .date] | join("-")' || true)

    if [ -z "$archive_name" ]; then
      bashio::log.error "Impossible to get backup info for $archive_name." \
        "Ensure it's a vaild backup file or disable deduplicate_archives option"
      continue
    fi

    borg_archive_name=$(bashio::config 'archive')-$archive_name
    if borg list | grep -Fqs "$borg_archive_name"; then
      bashio::log.info "Skipping archive $i, it's already in the archive"
      continue
    fi

    # Handle this manually till we can't use borg import-tar
    compressed=$(tar xf "$i" ./backup.json -O | jq -r '.compressed' || true)
    if [[ "$compressed" == 'false' ]]; then
      bashio::log.info "Archive $i, it's already uncompressed"
      finaltar="$i"
    else
      bashio::log.info "Archive needs to be uncompressed, extracting $i..."
      finaltar="$tmpdir/$(basename "$i")"
      tardir="$tmpdir/$(basename "$i" .tar)"
      mkdir "$tardir"
      tar xf "$i" -C "$tardir"

      for archive in "$tardir"/*.tar.*; do
        bashio::log.info "Decompressing $archive..."
        case "$archive" in
          *.gz)
            gunzip "$archive"
            ;;
          *.xz)
            unxz "$archive"
            ;;
          *.lz4)
            unlz4 "$archive"
            ;;
          *)
            bashio::log.error "Impossible to extract $archive in $archive_name." \
              "It won't be deduplicated"
            ;;
        esac
      done

      bashio::log.info "Recreating uncompressed tar in $finaltar..."
      [ -z "$timestamp" ] && timestamp="$i" || true
      tar cf "$finaltar" -C "$tardir" .
      recreated=true
      rm -r "$tardir"
    fi

    timestamp=$(tar xf "$finaltar" ./backup.json -O | jq -r '.date' | sed 's/\.[0-9:+]\+$//')

    bashio::log.info "Uploading backup $i as $archive_name."
    /usr/bin/borg create $(bashio::config 'create_options') \
      --timestamp "$timestamp" "::$borg_archive_name" "$finaltar" \
      || bashio::exit.nok "Could not upload backup $i."

    if [[ "$recreated" == true ]]; then
      rm -rf "$finaltar"
    fi
  done
else
  bashio::log.info 'Uploading backup.'
  /usr/bin/borg create $(bashio::config 'create_options') \
    "::$(bashio::config 'archive')-{utcnow}" /backup \
    || bashio::exit.nok "Could not upload backup."
fi

bashio::log.info 'Checking backups.'
borg check --archives-only -P "$(bashio::config 'archive')"

bashio::log.info 'Pruning old backups.'
/usr/bin/borg prune $(bashio::config 'prune_options') --list \
  -P $(bashio::config 'archive') \
  || bashio::exit.nok "Could not prune backups."

local_snapshot_config=$(bashio::config 'local_snapshot')
local_snapshot=$((local_snapshot_config + 1))

if [ $local_snapshot -gt 1 ]; then
  bashio::log.info 'Cleaning old snapshots.'
  cd /backup
  ls -tp | grep -v '/$' | tail -n +$local_snapshot | tr '\n' '\0' | xargs -0 rm -- || true
fi

bashio::log.info 'Finished.'
bashio::exit.ok
