#!/usr/bin/env bash

# zdump.sh v1.0
## Usage: 	zdump.sh <zvol>
## Cron hourly for best results.
#
## Snapshot the specified zvol then bzip the snapshot and save it to a specified directory.
## Automatically manage snapshots similar to autodump, with set numbers, "dump levels", and hourly N backups.
#
## zdump was written for and tested on FreeBSD 8.x and 9.x.
#
### Matt Stofko <matt@mjslabs.com>

# Base backup directory. Sets will be stored in $BACKUPDIR/<ZVOL>/setX where <ZVOL> is the zvol specified.
BACKUPDIR=/nfs/system_backup/zfs

# XXX update this so it is $MOUNTPOINT/$RESTOREDIR
# Where to create softlinks to the .zfs/snapshot directory. Preferably somewhere that all users who would need to restore can access.
# This will be prefixed by the mountpoint of the specified zvol. e.g. `zdump.sh tank/home` would create /home/$RESTOREDIR
RESTOREDIR=_restore

# Where to keep track of our current dump set. Like dump's dumpdates file.
DUMPDATES=/usr/local/etc/zdumpdates

# How many previous snapshots should be linked to in the RESTOREDIR/date directory?
BACKLINKS=48

########################################################################################
########################################################################################
############################### DO NOT CHANGE BELOW HERE ###############################
########################################################################################
########################################################################################

ZVOL=$1

# In case we need to kill the parent from find_bin
trap "exit 1" SIGTERM
TOP_PID=$$

echoerr() { echo "$@" 1>&2; }

find_bin()
{
    found=`which $1`
    if [[ "$found" == "" ]]; then
        echoerr "Cannot find $1 in your \$PATH."
		kill -s TERM $TOP_PID
    fi  

    echo $found
}

ZFS=`find_bin zfs`
BZIP=`find_bin bzip2`
GREP=`find_bin grep`
TAIL=`find_bin tail`
CUT=`find_bin cut`
RM=`find_bin rm`
LN=`find_bin ln`
DATE=`find_bin date`
MKDIR=`find_bin mkdir`
WC=`find_bin wc`
XARGS=`find_bin xargs`

# Check that we have a valid zvol
if [[ "$ZVOL" == "" || "`$ZFS list -Hrt snapshot $ZVOL 2>&1`" =~ ^cannot ]]; then
	echo "Need a valid zvol to work with. You specified '$ZVOL'."
	exit
fi

# Where is this zvol mounted? (used to find the .zfs dir and make the restore dir)
ZFSDIR=`$ZFS get -H mountpoint $ZVOL | $CUT -f 3`
RESTOREDIR=$ZFSDIR/$RESTOREDIR

# Get info for the last snapshot
SNAPS=`$ZFS list -Hrt snapshot $ZVOL | $CUT -f 1`

# This is our first time running, default to 0s
if [ -z "$SNAPS" ]; then
	NEXTSNAP=set0-l0-n0
	NEXTSET=0
	DIRSET=set0
	DIRLVL=0
	NEXTNUM=0
# Figure out our last run and determine what to do this time
else
	LASTSNAP=`echo "$SNAPS" | $TAIL -n 1`
	SNAPNAME=`echo $LASTSNAP | $CUT -d @ -f 2`
	LASTSET=`echo $SNAPNAME | $GREP -o "set[0-9]*"`
	LASTLVL=`echo $SNAPNAME | $GREP -o "l[0-9]*"`
	LASTNUM=`echo $SNAPNAME | $GREP -o "n[0-9]*"`

	# Defaults for the path we are going to write our zdump to
	DIRSET=$LASTSET
	DIRLVL=$LASTLVL

	# Increment the number of the dump
	NEXTNUM=`echo $(($(echo $LASTNUM | $CUT -c 2-)+1))`
	# If over the max...
	if [ "$NEXTNUM" == "24" ]; then
		# Reset to 0 and bump the level
		NEXTNUM=0
		NEXTLVL=`echo $(($(echo $LASTLVL | $CUT -c 2-)+1))`
		# If over the max...
		if [ "$NEXTLVL" == "10" ]; then
			# Reset to 0 and bump the set
			NEXTLVL=0
			NEXTSET=`echo $(($(echo $LASTSET | $CUT -c 4-)+1))`
			if [ "$NEXTSET" == "4" ]; then
				# Reset to 0
				NEXTSET=0
				NEXTSNAP=set${NEXTSET}-l${NEXTLVL}-n${NEXTNUM}
			fi
			DIRSET=set${NEXTSET}
			NEXTSNAP=set${NEXTSET}-l${NEXTLVL}-n${NEXTNUM}
		else
			NEXTSNAP=${LASTSET}-l${NEXTLVL}-n${NEXTNUM}
		fi
		DIRLVL=l${NEXTLVL}
	else
		NEXTSNAP=${LASTSET}-${LASTLVL}-n${NEXTNUM}
	fi
fi

# The snapshot we're about to take
NEWSNAP=${ZVOL}@${NEXTSNAP}

# Default to diffing against the last snapshot
DIFFFLAG="-i $LASTSNAP"

# Things to do when changing to a new set
if [ "$NEXTSET" != "" ]; then
	echo "Starting new zdump set: ${BACKUPDIR}/${ZVOL}/${DIRSET}."
	# Don't diff against a previous set
	DIFFFLAG=
	# Delete the snapshots in this set (e.g. we are coming back around to set0, so delete it for our new set0)
	DELSNAPS=`$ZFS list -Hrt snapshot $ZVOL | $GREP ${ZVOL}@set${NEXTSET} | $CUT -f 1`
	if [ "$DELSNAPS" != "" ]; then
		echo "$DELSNAPS" | $XARGS -L1 zfs destroy
	fi
	# Remove the destroyed snapshots from dumpdates
	$GREP -v "${ZVOL}@set${NEXTSET}" $DUMPDATES > $DUMPDATES
# If changing levels, e.g. l1-n23 -> l2-n0, need to diff l1-n0 and l2-n0.
elif [[ "$NEXTSET" == "" && "$NEXTNUM" == "0" && "$NEXTLVL" != "" && "$NEXTLVL" != "$LASTLVL" ]]; then
	# If we are going to be on n0, and we have nextlvl defined and it isn't the same as the last lvl
	# that should mean we need to diff $LASTSET-$LASTLVL-n0 with $NEXTSNAP
	DIFFFLAG="-i @${LASTSET}-${LASTLVL}-n0"
fi

# Snap and send
$ZFS snapshot $NEWSNAP

echo -e "${NEWSNAP}\t\t`$DATE`" >> $DUMPDATES

# Update our links in RESTOREDIR
$MKDIR -p ${RESTOREDIR}/date
$RM -f ${RESTOREDIR}/last_hour
$RM -f ${RESTOREDIR}/this_hour
$LN -s ${ZFSDIR}/.zfs/snapshot/${NEXTSNAP} ${RESTOREDIR}/date/`$DATE '+%m-%d-%Y_%H:%M'`
$LN -s ${ZFSDIR}/.zfs/snapshot/${SNAPNAME} ${RESTOREDIR}/last_hour
$LN -s ${ZFSDIR}/.zfs/snapshot/${NEXTSNAP} ${RESTOREDIR}/this_hour

DATEBACKS=`ls -t ${RESTOREDIR}/date/`
DCOUNT=`echo "$DATEBACKS" | $WC -l`
if [ $DCOUNT -gt $BACKLINKS ]; then
	echo "$DATEBACKS" | $TAIL -n $(($DCOUNT-$BACKLINKS)) | $XARGS -I % $RM ${RESTOREDIR}/date/%
fi

# Send it off
$MKDIR -p ${BACKUPDIR}/${ZVOL}/${DIRSET}/${DIRLVL}
$ZFS send $DIFFFLAG $NEWSNAP | $BZIP > ${BACKUPDIR}/${ZVOL}/${DIRSET}/${DIRLVL}/n${NEXTNUM}.zdump.bz2
