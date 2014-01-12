autodump v2.0
========
Automatic management of backup sets using dump.

By default, autodump will try to figure out what level of dump needs to be done, and when a new set should be started.
Tweak the settings at the top of the file to give it the parameters in which to run, then cron it.

Written for FreeBSD, and tested on Ubuntu 13.10 and CentOS 6.4. Requires bash, or compatible shell.


Usage
-----
With no arguments passed, autodump will try to figure things out based on the settings at the top of the file.

To specify a dump set and level:

    autodump.sh [set #] [dump level]


To get a status of things:

    autodump.sh --status


To get the last backup of a specific mount:

    autodump.sh --last <mount point>


Requirements
------------
autodump will run on FreeBSD, Ubuntu, and CentOS out of the box (maybe others), with the follow additions:
  - bash or compatible shell
  - dump (usually not part of Linux default install)

