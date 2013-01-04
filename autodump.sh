#!/usr/bin/env bash

# autodump.sh
## Usage: autodump.sh [week] [dump level]
#
## Dump devices with a dump flag of 1 in /etc/fstab to specified directory along with their md5sum.
## Automatically manage dump levels (if 0 was done last, do 1 this time, and so on) and weekly rotation.
#
## Written and used specifically on FreeBSD, not guaranteed to work on other systems.
## For system requirements see the *BIN variables below. Also needs a shell that supports {..} ranges (like bash).
# 
# TODO:
#	- Support GNU flags for appropriate commands.
#	- Autodetect binary paths.
#
### Matt Stofko <matt@mjslabs.com>

# Your fstab file, usually in /etc.
# Any device in here with a dump flag of '1' will be dumped using it's mount point without slashes as the file name.
# e.g. /home would be dumped to home.dump.bz2
FSTAB_FILE=/etc/fstab

# How many weeks of backups to keep.
# (dir names will be 0 through $TOTAL_WEEKS-1)
TOTAL_WEEKS=4

# Where will our dumps be saved to?
# dirs for each week and dump level will be made here.
BACKUP_DEST=/nfs/system_backup/dump

# Copy our kernel config as well. This allows you to set the nodump system flag on /usr/src.
KERNEL_CONFIG_DIR=/usr/src/sys/amd64/conf
KERNEL_CONFIG_NAME=DAEMON

# Path to the binaries we need.
DUMPBIN=/sbin/dump
BZ2BIN=/usr/bin/bzip2
SSLBIN=/usr/bin/openssl
CUTBIN=/usr/bin/cut
TAILBIN=/usr/bin/tail
HEADBIN=/usr/bin/head
AWKBIN=/usr/bin/awk
CPBIN=/bin/cp
CATBIN=/bin/cat
GREPBIN=/usr/bin/grep
XARGSBIN=/usr/bin/xargs
SEDBIN=/usr/bin/sed
MKDIRBIN=/bin/mkdir
FINDBIN=/usr/bin/find
STATBIN=/usr/bin/stat
SORTBIN=/usr/bin/sort

########################################################################################
########################################################################################
############################### DO NOT CHANGE BELOW HERE ###############################
########################################################################################
########################################################################################

# Figure out which devices we need to dump by looking for the 1 flag in /etc/fstab, then format them as
# dev:label, e.g. /dev/da0s1a:root. This will dump /dev/da0s1a to root<dump level>.dump.bz2.
DEVICES=`$CATBIN $FSTAB_FILE | $AWKBIN '{print $1 ":" $2 ":" $5}' | $GREPBIN -v ":0" | $GREPBIN -v "^#" | $CUTBIN -d: -f1-2 | $SEDBIN -e 's/\/$/root/' -e 's/:\//:/' | $XARGSBIN echo`

# The week dir it's going to go to if the user specified.
WEEK=$1

# Or if they didn't specify, figure it out by finding the last file made in our dir tree.
if [ "$WEEK" == "" ]
 then
	WEEK=`$FINDBIN $BACKUP_DEST -type f | $XARGSBIN $STATBIN -f '%m:%N' | $SORTBIN -nr | $CUTBIN -d : -f2- | $HEADBIN -n1 | $SEDBIN 's/.*week\([0-9]\).*/\1/'`
fi

# If the user specified a dump level, we'll use it for $NEXTDUMP.
NEXTDUMP=$2

# Was the last dump level provided by the user, or should we figure it out?
if [ "$NEXTDUMP" == "" ]
 then
	# Figure out the last dump level.
	LASTDUMP=`$DUMPBIN -W | $TAILBIN -n 1 | $SEDBIN 's/.*Level \([0-9]\).*/\1/'`
	# Add 1 to the last level, that is the level we will be using this time.
	NEXTDUMP=$(($LASTDUMP+1))
fi

# Last level was 9, meaning we should start over at 0 on a new week now.
# This will never trigger on a user-specified dump level unless they pass "10", but why would they do that?
if [ "$NEXTDUMP" == "10" ] 
 then
	NEXTDUMP=0

	# Now check for weekly rotation.
	# We will be moving to the next week since we just reset to level 0.
	WEEK=$(($WEEK+1))

	# Is the week we're about to use at the limit? (we actually want TOTAL_WEEKS-1 because we start at week 0)
	if [ "$WEEK" == "$TOTAL_WEEKS" ]
	 then
		WEEK=0
	fi
fi

# Make sure the dirs exist.
for i in {0..9} ; do $MKDIRBIN -p $BACKUP_DEST/week$WEEK/$i ; done

# Build the variables needed for the commands run in the for loop we're about to enter.
DUMP_PATH=$BACKUP_DEST/week$WEEK/$NEXTDUMP
DUMP_FILE_SUFFIX=$NEXTDUMP.dump.bz2
DUMP_MD5_SUFFIX=$DUMP_FILE_SUFFIX.md5sum
DUMP_FLAGS=Lauf

# Loop through the device:label set and do the backups.
for CURDEVLABEL in $DEVICES
 do
	# Devices we're going to work on
	CUR_DEV=`echo $CURDEVLABEL | $CUTBIN -d : -f 1`	
	# File we're going to save to.
	CUR_FILE=`echo $CURDEVLABEL | $CUTBIN -d : -f 2`

	# Do the dump.
	$DUMPBIN -$NEXTDUMP -$DUMP_FLAGS - $CUR_DEV | $BZ2BIN > $DUMP_PATH/$CUR_FILE$DUMP_FILE_SUFFIX
	# Calculate the md5.
	$SSLBIN md5 $DUMP_PATH/$CUR_FILE$DUMP_FILE_SUFFIX > $DUMP_PATH/$CUR_FILE$DUMP_MD5_SUFFIX
done

# Copy the kernel config we specified up top and md5 it.
$CPBIN $KERNEL_CONFIG_DIR/$KERNEL_CONFIG_NAME $DUMP_PATH
$SSLBIN md5 $DUMP_PATH/$KERNEL_CONFIG_NAME > $DUMP_PATH/$KERNEL_CONFIG_NAME.md5sum

# Further reading
# http://forums.freebsd.org/showthread.php?t=4901
# http://forums.freebsd.org/showthread.php?t=185
# http://www.rgrjr.com/linux/backup.html

## check mount points with multiple slashes.
