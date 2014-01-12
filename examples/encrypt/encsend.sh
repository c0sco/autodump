#!/usr/bin/env bash

# encsend.sh: called by encrypt.sh (autodump trigger), to encrypt files then send them to a remote host.

# ssh with the right identity file (or use .ssh/config)
sshcmd="ssh -i /home/you/.ssh/backupkey you@backuphost"

# where the backups will be sent to on the remote host
remoteroot=/backup-clone

# Who to encrypt the files for (GPG recipient)
gpgrecip=you@you.com

# $1 is the file we have, $2 is the name of the file we will be sending to
if [ -e "$1" ]; then
	dir=`dirname $2`
	$sshcmd "mkdir -p ${remoteroot}/$dir"
	cat $1 | gpg --encrypt --recipient $gpgrecip --trust-model always | $sshcmd "cat > ${remoteroot}/$2"
fi
