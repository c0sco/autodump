#!/usr/bin/env bash

# File to be run as an autodump trigger. Place this script in the TRIGGERS directory.
# Save encsend.sh somewhere else and make sure the path to it is properly set below.
# Using encsend.sh, will encrypt files from the backup that was just done and send them to a remote host.

# Path to the encsend script.
encsend=/root/bin/encsend.sh

# Enter the backup dir. $BACKUP_DEST in autodump.
cd $1

# For every file in setX/lvl, run encsend.sh on it, saving each file as <name>.gpg.
for i in $(eval echo $2/$3/*)
	do $encsend $i ${i}.gpg
done
