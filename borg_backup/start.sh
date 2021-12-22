#!/usr/bin/env bashio
export BORG_REPO="ssh://$(bashio::config 'user')@$(bashio::config 'host'):$(bashio::config 'port')/$(bashio::config 'path')"
export BORG_PASSPHRASE="$(bashio::config 'passphrase')"
export BORG_BASE_DIR="/data"
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK="yes"
export BORG_RSH="ssh -i ~/.ssh/id_ed25519 -o UserKnownHostsFile=/data/known_hosts"

PUBLIC_KEY=`cat ~/.ssh/id_ed25519.pub`

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

if [ "$(date +%u)" = 7 ]; then
  bashio::log.info 'Checking archive integrity. (Today is Sunday.)'
  /usr/bin/borg check \
    || bashio::exit.nok "Could not check archive integrity."
fi

for i in /backup/*.tar; do
  backup_info="$i: $(tar xf "$i" ./backup.json -O 2> /dev/null | jq -r '[.name, .date] | join(" | ")' || true)"
  bashio::log.info "Backing up $backup_info"
done

bashio::log.info 'Uploading backup.'
/usr/bin/borg create $(bashio::config 'create_options') \
  "::$(bashio::config 'archive')-{utcnow}" /backup \
  || bashio::exit.nok "Could not upload backup."

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
  ls -tp | grep -v '/$' | tail -n +$local_snapshot | tr '\n' '\0' | xargs -0 rm --
fi

bashio::log.info 'Finished.'
bashio::exit.ok
