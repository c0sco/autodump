#!/usr/bin/env bash

# autodump.sh v1.7
## Usage: 	autodump.sh [set #] [dump level]
##			autodump.sh --status
##			autodump.sh --last <mount point>
#
## Dump devices with a dump flag of 1 in /etc/fstab to a specified directory.
## Automatically manage dump levels (if 0 was done last, do 1 this time, and so on) and set rotations.
#
## Written and used specifically on FreeBSD, not guaranteed to work on other systems.
## For system requirements see the *BIN variables below. Also needs a shell that supports {..} ranges (like bash).
# 
# TODO:
#	- Support GNU flags for appropriate commands.
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
#  "everyother" - Do a level 0 every other set.
#  "set<number>" - Only do a level 0 on this set number. Number must be between 0 and $TOTAL_SETS - 1.
#  default (anything else) - Do a level 0 at the start of every new set.
DO_LVL0=set0

# At what dump level do we care about the 'nodump' flag? If this is 0, then files and directories tagged with the 
# 'nodump' flag (using chflags or chattr) will NEVER be backed up. If set to 1, then only on level 0 will they be
# backed up, etc. Passed directly to dump's -h flag.
NODUMPCARE=0

# Where will our dumps be saved to?
# dirs for each set and dump level will be made here.
BACKUP_DEST=/nfs/system_backup/dump

# The device that has your boot blocks on it, and the file it will be saved to.
# Can be left blank if you don't want to do this.
MBR_DEV=/dev/da0
MBR_FILE=mbr.img

# Copy our kernel config as well. This allows you to set the nodump system flag on /usr/src.
# Leave blank to disable this.
KERNEL_CONFIG_DIR=/usr/src/sys/amd64/conf
KERNEL_CONFIG_NAME=DAEMON

# File name of where the current system info will be saved after a backup.
LABEL_FILE=label.txt

# If you want to stick the pid file somewhere else (defaults to /var/run)
LOCKDIR=

# Path to the file that dump writes last backup time to. Defaults to /etc/dumpdates
DUMPDATES=

find_bin()
{
    found=`which $1`
    if [[ "$found" == "" ]]; then
        echo "Can't find $1 in your \$PATH. Exiting."
        exit
    fi

    echo $found
}

# Check to make sure we have all the bins we need.
DUMPBIN=`find_bin dump`
BZ2BIN=`find_bin bzip2`
SSLBIN=`find_bin openssl`
CUTBIN=`find_bin cut`
TAILBIN=`find_bin tail`
HEADBIN=`find_bin head`
AWKBIN=`find_bin awk`
CPBIN=`find_bin cp`
CATBIN=`find_bin cat`
GREPBIN=`find_bin grep`
XARGSBIN=`find_bin xargs`
SEDBIN=`find_bin sed`
MKDIRBIN=`find_bin mkdir`
FINDBIN=`find_bin find`
STATBIN=`find_bin stat`
SORTBIN=`find_bin sort`
HOSTBIN=`find_bin hostname`
UNAMEBIN=`find_bin uname`
DFBIN=`find_bin df`
DATEBIN=`find_bin date`
LSBIN=`find_bin ls`
DDBIN=`find_bin dd`
MVBIN=`find_bin mv`
TRBIN=`find_bin tr`
RMBIN=`find_bin rm`
DIRNAMEBIN=`find_bin dirname`
BASENAMEBIN=`find_bin basename`

########################################################################################
########################################################################################
############################### DO NOT CHANGE BELOW HERE ###############################
########################################################################################
########################################################################################

# Set a pid file (so we don't run dump twice)
set_lock_file ()
{
	__USEDIR=${LOCKDIR:-/var/run}
	__LOCKFILE=$__USEDIR/`$BASENAMEBIN $0`.pid

	if [ -e $__LOCKFILE ]
	  then
		echo "Error: $0 already running (pid: `$CATBIN $__LOCKFILE`). Exiting."
		exit
	fi

	if [ -d $USEDIR ]
	  then
		echo "$$" >> $__LOCKFILE
	else
		echo "Error: Can't make a lock file in '$USEDIR'! Exiting."
		exit
	fi
}

# Remove the pid file
rm_lock_file ()
{
	__USEDIR=${LOCKDIR:-/var/run}
	__LOCKFILE=$__USEDIR/`$BASENAMEBIN $0`.pid

	if [ -e $__LOCKFILE ]
	  then
		$RMBIN $__LOCKFILE
	fi
}

# Make sure to remove our pid file on exit
__cleanup ()
{
	rm_lock_file
	exit
}
trap __cleanup SIGINT SIGHUP SIGTERM EXIT

# Find the path to the most current set and level (i.e. the newest thing we got right now)
get_current_set ()
{
	echo `$FINDBIN $BACKUP_DEST -type f | $XARGSBIN $STATBIN -f '%m:%N' | $SORTBIN -nr | $CUTBIN -d : -f2- | $HEADBIN -n1 | $SEDBIN 's/.*set\([0-9]\).*/\1/'`
}

# Find the path to the oldest level 0 dump (i.e. the oldest "complete" thing we got)
get_oldest_zero ()
{
	THEPATH=`$FINDBIN $BACKUP_DEST -type f | $XARGSBIN $STATBIN -f '%m:%N' | $SORTBIN -nr | $CUTBIN -d : -f2- | $GREPBIN "0.dump.bz2" | $TAILBIN -n1`
	echo `$DIRNAMEBIN $THEPATH`
}

# Figure out the last level we did
get_last_lvl ()
{
	echo `$DUMPBIN -W | $GREPBIN -v "^Last" | $TAILBIN -n 1 | $SEDBIN 's/.*Level \([0-9]\).*/\1/'`
}

# Check permissions on things we need to use
check_perms ()
{
	if [ ! -r ${DUMPDATES:-/etc/dumpdates} ]
	  then
		echo "Can't read ${DUMPDATES:-/etc/dumpdates}! Exiting."
		exit
	fi

	if [[ ! -r $BACKUP_DEST || ! -x $BACKUP_DEST ]]
	  then
		echo "Can't read or traverse $BACKUP_DEST! Exiting."
		exit
	fi

	if [ ! -w ${DUMPDATES:-/etc/dumpdates} ]
	  then
		echo "Warning: Can't write to ${DUMPDATES:-/etc/dumpdates}! Detecting last backup time may not work properly." 1>&2
	fi
}

# Make sure we can access everything we need before we go on.
check_perms

# We just want a status. Don't actually back anything up.
if [[ "$1" =~ ^- ]]
  then
	if [ "$1" == "--status" ]
	 then
	 	echo "`$DUMPBIN -W`"
	 	echo "Path to last dump:" $BACKUP_DEST/set`get_current_set`/`get_last_lvl`
	 	echo "Path to oldest level 0:" `get_oldest_zero`
	elif [ "$1" == "--last" ]
	  then
	  	if [ "$2" != "" ]
		  then
			THEOUT=`$DUMPBIN -W | $GREPBIN -v "^Last" | $CUTBIN -d '(' -f2- | $GREPBIN "$2)"`
			if [ "$THEOUT" == "" ]
			  then
				echo "Couldn't find the last backup time for '$2'"
			else
				echo "$THEOUT" | $AWKBIN '{print $1 ": " $7 " " $8 " " $9 " " $10}' | $TRBIN -d ')'
			fi
		elif [ "$2" == "" ]
		  then
	  		echo "The --last option requires an argument (the name of the mount point)."
	  	fi
	else
		echo "No such option: '$1'"
	fi

	exit
fi

# Looks like we're going to start a backup, create the pid file.
set_lock_file

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
				# So start at 1
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
	echo "Moving $BACKUP_DEST/set$SET/0/* to the trash."
	$MKDIRBIN -p $BACKUP_DEST/trash
	$MVBIN $BACKUP_DEST/set$SET/0/* $BACKUP_DEST/trash
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
	CUR_FILE=`echo $CURDEVLABEL | $CUTBIN -d : -f 2 | $TRBIN / _`

	# Do the dump.
	$DUMPBIN -$NEXTDUMP -h $NODUMPCARE -$DUMP_FLAGS - $CUR_DEV | $BZ2BIN > $DUMP_PATH/$CUR_FILE$DUMP_FILE_SUFFIX
	# Calculate the md5.
	$SSLBIN md5 $DUMP_PATH/$CUR_FILE$DUMP_FILE_SUFFIX > $DUMP_PATH/$CUR_FILE$DUMP_MD5_SUFFIX
done

# Back up the boot blocks if specified.
if [ "$MBR_DEV" != "" ]
 then
 	$DDBIN if=$MBR_DEV of=$DUMP_PATH/$MBR_FILE bs=512 count=1
fi

# Copy the kernel config we specified up top and md5 it.
if [[ -e "$KERNEL_CONFIG_DIR" && -e "$KERNEL_CONFIG_NAME" ]]; then
	$CPBIN $KERNEL_CONFIG_DIR/$KERNEL_CONFIG_NAME $DUMP_PATH
	$SSLBIN md5 $DUMP_PATH/$KERNEL_CONFIG_NAME > $DUMP_PATH/$KERNEL_CONFIG_NAME.md5sum
fi

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
