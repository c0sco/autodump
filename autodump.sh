#!/usr/bin/env bash

# autodump.sh v1.1
## Usage: 	autodump.sh [set #] [dump level]
##			autodump.sh --status
#
## Dump devices with a dump flag of 1 in /etc/fstab to specified directory along with their md5sum.
## Automatically manage dump levels (if 0 was done last, do 1 this time, and so on) and set rotations.
#
## Written and used specifically on FreeBSD, not guaranteed to work on other systems.
## For system requirements see the *BIN variables below. Also needs a shell that supports {..} ranges (like bash).
# 
# TODO:
#	- Support GNU flags for appropriate commands.
#	- Autodetect binary paths.
#	- Support mount points with multiple slashes.
#
# Further reading
# http://forums.freebsd.org/showthread.php?t=4901
# http://forums.freebsd.org/showthread.php?t=185
# http://www.rgrjr.com/linux/backup.html
#
### Matt Stofko <matt@mjslabs.com>

# Your fstab file, usually in /etc.
# Any device in here with a dump flag of '1' will be dumped using it's mount point without slashes as the file name.
# e.g. /home would be dumped to home.dump.bz2
FSTAB_FILE=/etc/fstab

# How many sets of backups to keep.
# (dir names will be 0 through $TOTAL_SETS-1)
TOTAL_SETS=4

# When to do a level 0 dump.
# Options are:
#  "every" - Do a level 0 at the start of every new set.
#  "everyother" - Do a level 0 every other set.
#  set<number> - Only do a level 0 on this set number. Number must be between 0 and $TOTAL_SETS - 1.
DO_LVL0=set0

# Where will our dumps be saved to?
# dirs for each set and dump level will be made here.
BACKUP_DEST=/nfs/system_backup/dump

# The device that has your boot blocks on it, and the file it will be saved to.
# Can be left blank if you don't want to do this.
MBR_DEV=/dev/da0
MBR_FILE=mbr.img

# Copy our kernel config as well. This allows you to set the nodump system flag on /usr/src.
KERNEL_CONFIG_DIR=/usr/src/sys/amd64/conf
KERNEL_CONFIG_NAME=DAEMON

# File name of where the current system info will be saved after a backup.
LABEL_FILE=label.txt

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
HOSTBIN=/bin/hostname
UNAMEBIN=/usr/bin/uname
DFBIN=/bin/df
DATEBIN=/bin/date
LSBIN=/bin/ls
DDBIN=/bin/dd
MVBIN=/bin/mv

########################################################################################
########################################################################################
############################### DO NOT CHANGE BELOW HERE ###############################
########################################################################################
########################################################################################

get_current_set ()
{
	echo `$FINDBIN $BACKUP_DEST -type f | $XARGSBIN $STATBIN -f '%m:%N' | $SORTBIN -nr | $CUTBIN -d : -f2- | $HEADBIN -n1 | $SEDBIN 's/.*set\([0-9]\).*/\1/'`
}

get_last_lvl ()
{
	echo `$DUMPBIN -W | $GREPBIN -v "^Last" | $TAILBIN -n 1 | $SEDBIN 's/.*Level \([0-9]\).*/\1/'`
}

# We just want a status. Don't actually back anything up.
if [ "$1" == "--status" ]
 then
 	echo "`$DUMPBIN -W`"
 	echo "Path to last dump:" $BACKUP_DEST/set`get_current_set`/`get_last_lvl`
	exit 	
fi

# Figure out which devices we need to dump by looking for the 1 flag in /etc/fstab, then format them as
# dev:label, e.g. /dev/da0s1a:root. This will dump /dev/da0s1a to root<dump level>.dump.bz2.
DEVICES=`$CATBIN $FSTAB_FILE | $AWKBIN '{print $1 ":" $2 ":" $5}' | $GREPBIN -v ":0" | $GREPBIN -v "^#" | $CUTBIN -d: -f1-2 | $SEDBIN -e 's/\/$/root/' -e 's/:\//:/' | $XARGSBIN echo`

# The set dir it's going to go to if the user specified.
SET=$1

# Or if they didn't specify, figure it out by finding the last file made in our dir tree.
if [ "$SET" == "" ]
 then
	SET=`get_current_set`
fi

# If the user specified a dump level, we'll use it for $NEXTDUMP.
NEXTDUMP=$2

# Was the last dump level provided by the user, or should we figure it out?
if [ "$NEXTDUMP" == "" ]
 then
	# Figure out the last dump level.
	LASTDUMP=`get_last_lvl`
	# Add 1 to the last level, that is the level we will be using this time.
	NEXTDUMP=$(($LASTDUMP+1))

	# In case we've never done a dump before, start at 0/0
	if [ "$LASTDUMP" == "" ]
	 then
	 	NEXTDUMP=0
	 	SET=0
	fi
fi

# Last level was 9, meaning we should start over at 0 on a new set now.
# This will never trigger on a user-specified dump level unless they pass "10", but why would they do that?
if [ "$NEXTDUMP" == "10" ] 
 then
	NEXTDUMP=0

	# Now check for set rotation.
	# We will be moving to the next set since we just reset to level 0.
	SET=$(($SET+1))

	# Is the set we're about to use at the limit? (we actually want TOTAL_SETS-1 because we start at set 0)
	if [ "$SET" == "$TOTAL_SETS" ]
	 then
		SET=0
	fi
fi

# Check if this set is OK to do a level 0 dump on 
if [ "$NEXTDUMP" == "0" ]
 then
	# As long as the user hasn't specified a set #
	if [ "$1" == "" ]
	 then
	 	# If we only want level 0s on every other set, then make sure the last set didn't have one.
	 	if [ "$DO_LVL0" == "everyother" ]
	 	 then
	 	 	if [ "$SET" == "0" ]
	 	 	 then
	 	 	 	LASTSET=$(($TOTAL_SETS-1))
	 	 	 else
	 	 	 	LASTSET=$(($SET-1))
	 	 	fi

	 	 	# Now go look for a level 0 in the last set
	 	 	LASTSET0=`$LSBIN $BACKUP_DEST/set$LASTSET/0`
	 	 	if [ "$LASTSET0" != "" ]
	 	 	 then
	 	 	 	# We did a 0 last set, and we are set to "everyother", so start at 1.
	 	 	 	NEXTDUMP=1
	 	 	 	# And mark the level 0 dir for deletion, otherwise we can get confused about when we did a lvl0 last.
	 	 	 	DELETE0=yes
	 	 	fi
	 	# Not "everyother", but a specific set number
	 	elif [[ "$DO_LVL0" =~ ^set ]]
	 	 then
	 	 	# We want 0s on a specific set, and we are not currently on that set
	 		if [ "$DO_LVL0" != "set$SET" ]
	 		 then
	 		 	# So start at 0
	 			NEXTDUMP=1
	 			# And mark level 0 for deletion just in case we switch to "everyother" at some point in the future
	 			DELETE0=yes
	 		fi
	 	fi
	fi
fi

# "trash" the level 0 in this set because of our DO_LVL0 setting.
# This just moves it to the trash folder, since we'd rather not rm backups until we absolutely have to.
if [ "$DELETE0" == "yes" ]
 then
 	DELPATH="$BACKUP_DEST/set$SET/0/*"
	echo "Moving $DELPATH to the trash."
	$MKDIRBIN -p $BACKUP_DEST/trash
	$MVBIN $DELPATH $BACKUP_DEST/trash
fi

# Make sure the dirs exist.
for i in {0..9} ; do $MKDIRBIN -p $BACKUP_DEST/set$SET/$i ; done

# Build the variables needed for the commands run in the for loop we're about to enter.
DUMP_PATH=$BACKUP_DEST/set$SET/$NEXTDUMP
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

# Back up the boot blocks if specified.
if [ "$MBR_DEV" != "" ]
 then
 	$DDBIN if=$MBR_DEV of=$DUMP_PATH/$MBR_FILE bs=512 count=1
fi

# Copy the kernel config we specified up top and md5 it.
$CPBIN $KERNEL_CONFIG_DIR/$KERNEL_CONFIG_NAME $DUMP_PATH
$SSLBIN md5 $DUMP_PATH/$KERNEL_CONFIG_NAME > $DUMP_PATH/$KERNEL_CONFIG_NAME.md5sum

# Gather system info to label our dumps
DUMP_LISTING=`$LSBIN -loh $DUMP_PATH`
echo Dump Date: `$DATEBIN` > $DUMP_PATH/$LABEL_FILE
echo Dump Level: $NEXTDUMP >> $DUMP_PATH/$LABEL_FILE
echo Dump Files: >> $DUMP_PATH/$LABEL_FILE
echo "$DUMP_LISTING" >> $DUMP_PATH/$LABEL_FILE
echo >> $DUMP_PATH/$LABEL_FILE

echo Hostname: `$HOSTBIN` >> $DUMP_PATH/$LABEL_FILE
echo Version: `$UNAMEBIN -a` >> $DUMP_PATH/$LABEL_FILE
echo >> $DUMP_PATH/$LABEL_FILE

echo Disk Usage: >> $DUMP_PATH/$LABEL_FILE
$DFBIN -h >> $DUMP_PATH/$LABEL_FILE
echo >> $DUMP_PATH/$LABEL_FILE

echo Disk Layout: >> $DUMP_PATH/$LABEL_FILE
$CATBIN $FSTAB_FILE >> $DUMP_PATH/$LABEL_FILE
