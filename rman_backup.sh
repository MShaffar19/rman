#!/bin/ksh93

#------------------------------------------------------------------
# ********* RMAN backups script	 	rman_backup.ksh ***************
#
# See rman_backup.info for Script functionality and general information.
# See rman_docs.txt for references to Oracle documentation.
#
# Supported - Oracle releases: tested on 9i, 10g and 11g databases;
#     		- platforms: Linux, AIX 5.1+, (HP-UX 11.11 - support discontinued)
# 			- backup destinations: On disk backups, Commvault, TSM;
# 			- RMAN catalog and non-cataloged backups are supported.
#

#logs will be in $BASE_PATH/log, generated script in $BASE_PATH/scripts and lock files in $BASE_PATH/lock
BASE_PATH=$( cd "$( dirname "$0" )" && pwd )

#Process server-specific parameters first from rman_backup.ksh.vars
#If you need to update any type of the script's behaviour - look there first.
. $BASE_PATH/rman_backup_vars.sh


#------------------------------------------------------------------
if [ $# -lt 2 ] ; then		#not given enough parameters to script
	cat <<USAGEINFO
USAGE:  rman_backup.ksh <operation> <SID>[:DG] [<SID>[:DG] <SID>[:DG] ...]
where <operation> is one of
	- FULL - make a full DB backup, regardless day of the week.
	- INCR - make an incremental DB backup, regardless day of the week.
	- DB - full backups on Saturdays, and INCREMENTAL LEVEL 1 CUMULATIVE - other days;
	- ARCH - to backup archive logs (usually scheduled hourly).
	- XCHK - run CROSSCHECK and RMAN reports.

	<SID> may be optionallly followed by :DG which means that this is a DataGuarded database,
	and backup should run only from standby to offload primary database.
	If you do this, then add both nodes' SYS passwords to Oracle Wallet.
	
	See rman_backup.info for more information.
USAGEINFO
	exit 1
fi


#Only for Dataguarded databases: We need to connect to primary db to archive current log.
#Oracle Wallet is used to store password for the databases. See rman_backup.info for OW details.


#------------------------------------------------------------------
# ! no changes should be made below !
#------------------------------------------------------------------
#
# ******** Functions:								***************

#Load low-level and utility functions rman_backup.ksh.subs:
. $BASE_PATH/rman_backup_subs.sh


#------------------------------------------------------------------

function backup_control_and_spfile {
#Backs to $BASE_PATH/scripts/ 1)control file to as binary and as text script file; 2) pfile from spfile.
#Also backs as rman backup set control and sp files.
	dt="_`date '+%Y%m%d'`"
	SCRIPT="$SCRIPT
		BACKUP $compressed SPFILE INCLUDE CURRENT CONTROLFILE TAG 'sp_ctlf_$db';
		SQL \"ALTER DATABASE BACKUP CONTROLFILE TO TRACE AS ''$BASE_PATH/scripts/controlf-$db$dt.txt-bkpcopy'' REUSE\";
		SQL \"ALTER DATABASE BACKUP CONTROLFILE TO          ''$BASE_PATH/scripts/controlf-$db$dt.ctl-bkpcopy'' REUSE\";
		SQL \"CREATE PFILE=''$BASE_PATH/scripts/init$db$dt.ora-bkpcopy'' FROM SPFILE\";"
	##do resync catalog here also if DG and primary
	case "$DB_ROLE.$MODE.$USE_CATALOG" in
		PRIMARY.CTRL.1)	SCRIPT="$SCRIPT
							RESYNC CATALOG;"
	esac
}
function backup_archive_logs {
	archive_log_current	#ALTER SYSTEM ARCHIVE LOG CURRENT on PRIMARY node (or current for non-DG database)
	SCRIPT="$SCRIPT
	        BACKUP $compressed ARCHIVELOG ALL 
			$arch_backup_options TAG 'arch_logs'
			"
	if [ $Ver10up -eq 1 ]; then
		#if FRA is enabled, do not delete archived logs explicitly, use retention policy/
		#  database auto management instead, so FRA will serve as a cache for archived logs
		#  in some sense
		SCRIPT="$SCRIPT;"
	else
		#As 9i databases do not delete anything automatically...
		SCRIPT="$SCRIPT DELETE INPUT;
			DELETE OBSOLETE;"
	fi
}
function backup_database {
	SCRIPT="BACKUP $compressed $MODE DATABASE 
		 	$db_backup_options TAG '$tags';"
	backup_archive_logs
	backup_control_and_spfile
}
#-------------------------------------------
function run_the_script {
	if [ $BACKUP_DEBUG -eq 1 ]; then
		echo "DEBUG: RMAN script: $SCRIPT"
		rman_debug="$LOGFILE.rman-trace"
		echo "DEBUG: RMAN trace file: $rman_debug"
		rman_debug="DEBUG TRACE=$rman_debug"
	fi

	echo "INFO: rman target=$rman_target"
	$NICE $ORACLE_HOME/bin/rman target=$rman_target $rman_debug <<EOF
$SCRIPT
EOF
}
#-------------------------------------------
function DO_RMAN_BACKUP {
	p=$BACKUP_PARALLELISM
	case $MODE in
			ARCH)	backup_archive_logs
					#Do more frequent control file backups in case of PITR to an older incarnation:
					backup_control_and_spfile
					;;
			CTRL)	# this mode is only used in DG mode - will run control file backup on *primary* : 
					backup_control_and_spfile	;	p=1	
					;;
			*)		backup_database				;;
	esac

	prepare_channels $p
	rman_configures

	SCRIPT="$RMAN_INIT
RUN {	$RMAN_HEADER_SCRIPT
$RMAN_CHANNELS
$SCRIPT
$RMAN_TRAIL_SCRIPT $RMAN_RELEASE_CHANNELS
}
"
	renice_rman &
	renice_pid=$!

	run_the_script

	kill $renice_pid >/dev/null 2>&1
}

#-------------------------------------------


function DO_BACKUP_CROSSCHECK {
#-------------------------------------------
	#This subroutine will run RMAN CROSSCHECKs and several RMAN REPORT commands.
	#What DO_BACKUP_CROSSCHECK is not about?
	#	We assume that you use FRA to manage backups according to retention policy.
	#	So it will NOT DELETE either expired nor obsolete - run them manually at your own risk.
	#	Or you may also use third-party backup solutions that enforce their own retention.
	#How this should be used best?
	#	Schedule weekly/monthly and let DBAs review carefully results email
	#	and react immediately if any discrepancy was found.

	prepare_maintenance_channels

	SCRIPT="$RMAN_INIT
$RMAN_CHANNELS
#-- Run crosschecks and then report backup pieces and archived logs found as missing.
CROSSCHECK BACKUP completed after 'SYSDATE-$RECOVERY_WINDOW-5';
LIST EXPIRED BACKUP;

CROSSCHECK ARCHIVELOG ALL completed after 'SYSDATE-$RECOVERY_WINDOW-5';
LIST EXPIRED ARCHIVELOG ALL;

#-- Report what's affected by certain NOLOGGING operations and can't be recovered
REPORT UNRECOVERABLE;

#-- What's stored more than target retention policy
REPORT OBSOLETE;

#-- Backups that need more than 1 day of archived logs to apply:
REPORT NEED BACKUP DAYS 1;
#-- Backups that need more than 7 incremental backups for recovery:
REPORT NEED BACKUP INCREMENTAL 7;

#-- Displays objects requiring backup to satisfy a recovery window-based retention policy.
REPORT NEED BACKUP RECOVERY WINDOW OF $RECOVERY_WINDOW DAYS;
$RMAN_RELEASE_CHANNELS
"
	run_the_script
}


#-------------------------------------------
function script_mode_FULL {
	MODE="INCREMENTAL LEVEL 0"
	tags='dbfiles_full'
}
function script_mode_INCR {
	MODE="INCREMENTAL LEVEL 1 $CUMULATIVE"
	tags="dbfiles_cumul"
	db_backup_options=$db_backup_incr_options
}
function script_mode_DB {
	case `date '+%u'` in
			$FULL_BKP_DAY)	script_mode_FULL ;;		#Full backup day
						*)	script_mode_INCR ;;		#all other days - incremental backup
	esac
}
function script_mode_ARCH {
	MODE="ARCH"						#archive logs only
	tags='arch_logs'
}
function script_mode_XCHK {
	MODE="XCHK"						#rman crosscheck archivelog, backup
	tags='xchk'
}


#------------------------------------------------------------------
# Start of Main part of the script
#------------------------------------------------------------------
cd $BASE_PATH; orig_PATH=$PATH
#Where we put all the log files, gererated restore scripts and lock files:
mkdir -p $BASE_PATH/log $BASE_PATH/scripts $BASE_PATH/lock

LOGFILE0=$BASE_PATH/log/rmanbackup_`date '+%Y%m'`.log
{	echo "===== Starting $* pid=$$ on $HOSTNAME @ `date` ...."	

	case $1 in
		FULL|INCR|DB)		simul_run_check="DB"
							eval "script_mode_$1"
							;;
		ARCH|XCHK)			simul_run_check=$1
							eval "script_mode_$1"
							;;
		*)					usage	;;
	esac

	#Don't allow to run more than one RMAN shell script of the same function (DB, ARCH or XCHK).
	lock_it
	trap release_lock INT TERM EXIT

	shift; allsids=$*
} 2>&1 >> $LOGFILE0

#------------------------------------------------------------------
# MAIN loop - through all the databases specified in command line
#------------------------------------------------------------------
for db in $allsids
do
	parse_params

	LOGFILE=$BASE_PATH/log/rmanbackup_`date '+%Y%m%d%H%M'`_${db}_$tags.log

	#-----------------------------------------------
	{	echo "===== Starting $MODE for $db @ `date`...."
		reset_global_vars
		[ $? -ne 0 ] && continue	#if $db isn't found in $ORATAB

		get_database_info
		check_best_practices

		if [ "x$DG" = 'xDG' ]; then
			DataGuard_check_and_prepare
			[ $? -ne 0 ] && continue	#XCHK doesn't run on primary.
		fi

		echo "INFO: Backup type: $MODE $DG"

		if [ "x$MODE" = 'xXCHK' ]; then
			DO_BACKUP_CROSSCHECK

		else   #-- all other (non-crosscheck) backup operations:

			if [ $BACKUP_COMPRESS -eq 1  -a  $Ver10up -eq 1 ]; then
				compressed="AS COMPRESSED BACKUPSET"
				echo "INFO: RMAN compression enabled."
			fi

			check_FRA 99				# 0. Check if FRA is defined and not full.
			if [ $? -eq $NO_FRA ] ; then	#If Flash Recovery Area is not configured, then 
				continue					#  skip this database
			fi

			DO_RMAN_BACKUP				# 1. run the RMAN backup script

			generate_clone_script		# 1.1. generate script to clone database
			report_backup_size			# 1.2. report backup size
		fi

		check_FRA $FRA_WARN_THR		# 2. check Flash Recovery Area space *after* backup - warn if 92% or more used

		report_runtime
		check_and_email_results		# 3. check for RMAN- and ORA- errors in the $LOGFILE

		echo "===== Completed $MODE for $db @ `date`."
	} 2>&1 >> $LOGFILE
	#-----------------------------------------------
# End of $allsids Loop 
done

{	release_lock
	remove_old_files

	echo "===== Finished backup with pid=$$ on $HOSTNAME @ `date` ...."	
} 2>&1 >> $LOGFILE0


#------------------------------------------------------------------
# End Main												***********
#------------------------------------------------------------------
exit 0
