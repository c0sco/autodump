autodump v1.5
========

Automatic management of backup sets using dump.


	Usage: 	
		autodump.sh [set #] [dump level]
		autodump.sh --status
		autodump.sh --last <mount point>

By default, autodump will try to figure out what level of dump needs to be done, and when a new set should be started.
Tweak the settings at the top of the file to give it the parameters in which to run, then cron it.

Requires bash, or compatible shell.
