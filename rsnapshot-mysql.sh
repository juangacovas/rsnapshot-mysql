#!/bin/bash
############################################################################################################################################################################
#
# rsnapshot-mysql.sh
#
# This is a rsnapshot friendly tool to pull all MySQL DBs from a host, One File Per Table.
#
############################################################################################################################################################################
#
#   By Juanga Covas 2015-2018
#
#   	with tips from http://dba.stackexchange.com/questions/20/how-can-i-optimize-a-mysqldump-of-a-large-database
############################################################################################################################################################################
#
# Features:
#
#   - Handle dumps from local or remote MySQL hosts.
#   - Allows to choose compression type for dumps (none, gzip or bzip2).
#   - Automatically fetches database names from mysql host and creates a directory for each database.
#	- Dump each table to its own file (.sql, .sql.gz or .sql.bz2) under a directory named as the database.
#   - Handle dump of mixed database tables using MyISAM AND/OR InnoDB...
#	- Ready to work with "backup_script" feature of rsnapshot, an incremental snapshot utility for local and remote filesystems.
#   - Creates a convenient restore script (BASH) for each database, under each dump directory.
#   - Creates backup of GRANTs (mysql permissions), and info files with the list of tables and mysql version.
#
############################################################################################################################################################################

# The main reason to dump tables to individual files, instead of a full file per database is to save more disk space when using incremental, link-based backup systems.
# This way more files have a chance to be 'the same than previous backup or snapshot', at the cost of a more complicated restore process which is also provided by this script.
# Having individual files per table also allows to better 'mysqldump' the tables of different engines: InnoDB (--single-transaction) or MyISAM (--lock-tables)

## START EDITING VARIABLES HERE:

# Path where a directory <databasename> will be created for each database (no trailing slash).
# If you're using rsnapshot, this directory should be somewhere in the current working directory
# BACKUP_DIR="."
BACKUP_DIR="./mysqldumps"

# Define which databases to exclude when fetching database names from mysql host
# Normally you always want to exclude mysql, Database, information_schema and performance_schema
MYSQL_EXCLUDE_DB="(^mysql$|^Database$|information_schema|performance_schema|^phpmyadmin$|^test_|_test$|_bak$|^bak_)"

MYSQL_EXCLUDE_TABLES="(\.sp_geodb_)"

# File to hold [client] host, port, user and password (data source)
MYSQL_CNF_FILE="/root/rsnapshot-mysql.cnf"

# This is the format for the credentials at cnf file:
#
# [client]
# user = db_username
# password = yourpassword
### host = xxx
### port = 3306

# Suffix to database name for the restore script (so you do not accidentally restore tables over the existing database).
# The restore script will try to create databasename plus RESTOREDB_SUFFIX, and will DROP TABLES if they exist.
# If you do now want a suffix, just comment the following line or leave the string empty
RESTOREDB_SUFFIX="_restored"

# If CLEAN_DUMP_DIRS is set to 1, all files inside each databasename directory will be deleted before the dumps
# When using rsnapshot tool, CLEAN_DUMP_DIRS=0 is OK since all files and dirs created by this script at working dir. will be moved
CLEAN_DUMP_DIRS=0

# uncomment this line if you want to check all tables before trying to dump
#CHECK_TABLES="please"

##
# normally you don't want to touch anything else beyond this point of the script
##


# Get a display date for the current date and time
TIMESTAMP=$(date +"%Y-%m-%d-%H.%M")

# show banner
echo "-----------------------------------------------------------------------------------------"
echo "rsnapshot-mysql.sh    by Juanga Covas 2015-2017"
echo " "
echo " Rsnapshot friendly tool to pull all MySQL DBs from a host, One File Per Table."
echo " "

# show usage if not enough arguments are given
if [ -z $3 ] ;then
	echo " "
	echo "Required parameters: dbhost     compression   port  [file.cnf]	[test]"
	echo "            Example: localhost  none|gz|bz2   3306  default.cnf	test"
	echo " "
	echo "  Will try to connect using credentials from file.cnf (defaults to: $MYSQL_CNF_FILE)"
	exit 1;
fi

# create our own vars from arguments
MYSQL_HOST=$1
COMPRESSION=$2
MYSQL_PORT=$3
CLIENT_CNF=$4
TEST_RUN=$5

if [ ! -z "$CLIENT_CNF" ] ;then
	MYSQL_CNF_FILE=$CLIENT_CNF
fi

# common flags for mysqldump command
MYSQL_DUMP_FLAGS="--compress --hex-blob --force --skip-dump-date"

if [[ $MYSQL_HOST == "localhost" ]] || [[ $MYSQL_HOST == "127.0.0.1" ]] ;then
	# do not need to compress if host is localhost
	MYSQL_DUMP_FLAGS="--hex-blob --force --skip-dump-date"
fi

# check the provided file for mysql password
if [ ! -f $MYSQL_CNF_FILE ] ;then
	echo "ERROR: Cannot read: $MYSQL_CNF_FILE"
	exit 1
fi
if [ ! -s $MYSQL_CNF_FILE ] ;then
	echo "ERROR: File is empty: $MYSQL_CNF_FILE"
	exit 1
fi

# Deprecated method of getting mysql password...
# get mysql password from defined file, expecting one line, one word, filtering any newlines
# MYSQL_PASSWORD=`printf "%s" "$(< $MYSQL_PASSWORD_FILE)"`

# host, user, password for mysql
MYSQL_HUP="--defaults-extra-file=$MYSQL_CNF_FILE --host=$MYSQL_HOST --port=$MYSQL_PORT"

echo "Will try to dump databases from [$MYSQL_HOST] to: [$BACKUP_DIR] using [$MYSQL_CNF_FILE] [$MYSQL_HUP]"
echo " "
if [ ! -z "$TEST_RUN" ] ;then
	echo "(TEST RUN) Will NOT dump anything."
	echo " "
fi

if [[ $COMPRESSION == "gz" ]] ;then
	echo "Compress to .sql.gz (gzip)"
else
	if [[ $COMPRESSION == "bz2" ]] ;then
		echo "Compress to .sql.bz2 (bzip2)"
	else
		if [[ $COMPRESSION == "none" ]] ;then
			echo "No compression: .sql"
		else
			echo "ERROR: valid compression parameter is none|gz|bz2"
			exit 1;
		fi
	fi
fi

# try to create the given BACKUP_DIR, no errors, recursive
mkdir -p $BACKUP_DIR

# test connection to given mysql host by using mysqlshow
echo " "
printf 'Testing connection to MySQL ... '

RESULT=`mysqlshow $MYSQL_HUP | grep -v Wildcard | grep -o Databases`
if [[ "$RESULT" == "Databases" ]]; then
	printf "OK.\n"
else
	printf "ERROR: Cannot connect to MySQL server. Aborting. Using password from: $MYSQL_CNF_FILE\n\n"
	exit 1;
fi

# dump mysql host version info
echo " "
echo "MySQL version info"
if [ -z "$TEST_RUN" ]; then
	mysql $MYSQL_HUP --skip-column-names -e"SHOW VARIABLES LIKE '%version%';" > $BACKUP_DIR/mysql-version-$MYSQL_HOST.txt
fi
mysql $MYSQL_HUP --skip-column-names -e"SHOW VARIABLES LIKE '%version%';"
echo " "

# check tables?
if [ ! -z "$CHECK_TABLES" ]; then
	echo "Doing a mysqlcheck --all-databases --check --auto-repair"
	while read line; do

	  # skip database tables that are okay
	  echo "$line"|grep -q OK$ && continue

	  echo "WARNING: $line"
	done < <(mysqlcheck $MYSQL_HUP --all-databases --check --all-in-1 --auto-repair)
	echo " "
fi

# dump grants
if [ -z "$TEST_RUN" ]; then
	echo "Dumping GRANTs to $BACKUP_DIR/mysql-grants-$MYSQL_HOST.sql"
	mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | mysql --defaults-extra-file=$MYSQL_CNF_FILE --host=$MYSQL_HOST --port=$MYSQL_PORT --no-auto-rehash --skip-column-names | sed 's/$/;/g' > $BACKUP_DIR/mysql-grants-$MYSQL_HOST.sql
else
	echo "(TEST RUN) Skipping GRANTs dump"
fi
echo " "


# get database list
echo "Getting database list to dump ... "
echo " "

databaselist=`mysql $MYSQL_HUP --no-auto-rehash -e "SHOW DATABASES;" | grep -Ev "$MYSQL_EXCLUDE_DB"`

# begin to dump

# loop all database names
for db in $databaselist; do

	# exclude system and other databases
	if [[ $db == "mysql" ]] || [[ $db == "phpmyadmin" ]] ;then
		continue
	fi

	# create a sub-directory using database name, no errors, recursive
	mkdir -p $BACKUP_DIR/$db

	if test $CLEAN_DUMP_DIRS -eq 1 ;then
		echo "Cleaning files: $BACKUP_DIR/$db/{*.sql*,*.txt}"
		rm -f $BACKUP_DIR/$db/*.sql* $BACKUP_DIR/$db/*.txt
	fi


	if [ ! -z "$TEST_RUN" ]; then
		printf 'Found DB: %s \n' $db
	else
		printf 'Dumping DB: %s \n' $db
	fi

	# get a list of db.table.engine
	db_table_engine_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name,'.',engine) FROM information_schema.tables WHERE table_schema = '${db}'" | grep -Ev "$MYSQL_EXCLUDE_TABLES"`
	db_table_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name) FROM information_schema.tables WHERE table_schema = '${db}'" | grep -Ev "$MYSQL_EXCLUDE_TABLES"`

	# save the db table list
	# if [ -z "$TEST_RUN" ]; then
		echo $db_table_list > $BACKUP_DIR/$db/$db-tablelist.txt
		echo $db_table_engine_list > $BACKUP_DIR/$db/$db-engine-table-list.txt
	# fi

	# prepare first chunk of the bash restore script
	restore_file="$BACKUP_DIR/restore-$db.sh"
	dbr="${db}${RESTOREDB_SUFFIX}"

	echo "#!/bin/bash

	#########################################################################
	#
	#	Database Restore Script
	#
	#	    Backup done from host: $MYSQL_HOST
	#		         Database: $db
	#		      Backup date: $TIMESTAMP
	#
	#########################################################################

	#RESTOREDB=\"$db\"
	RESTOREDB=\"$dbr\"

	MYSQL_HOST=\$1
	MYSQL_CNF_FILE="$MYSQL_CNF_FILE"

	# checks

	if [ \"\$BASH\" != \"/bin/bash\" ] ;then
	    echo \"Please execute the script using /bin/bash\"
	    exit 1;
	fi
	if [ -z \"\$1\" ] ;then
		echo \"Expecting target mysql host as parameter\"
		exit 1
	fi
	if ls $db/$db*.sql* 1> /dev/null 2>&1; then
	    echo \"File check OK\"
	else
	    echo \"Cannot find $db.sql* files. Please execute the script under its directory.\"
	    exit 1
	fi
	if [ ! -f \$MYSQL_CNF_FILE ] ;then
		echo \"Cannot read: \$MYSQL_CNF_FILE\"
		exit 1
	fi
	if [ ! -s \$MYSQL_CNF_FILE ] ;then
		echo \"File is empty: \$MYSQL_CNF_FILE\"
		exit 1
	fi

	echo \" \"
	echo \"Database Restore Script\"
	echo \" \"
	echo \" Backup done from host: $MYSQL_HOST\"
	echo \"              Database: $db\"
	echo \"           Backup date: $TIMESTAMP\"
	echo \" \"
	echo \"RESTORE TO HOST: \$1\"
	echo \"  RESTORE TO DB: \$RESTOREDB\"
	echo \" \"
	echo \"#########################################################################\"
	echo \"NOTICE! Restore will DROP each TABLE for each backup file, but does NOT drop *other* tables that may exist.\"
	echo \" \"
	for DBTBNG in \`cat $db/$db-engine-table-list.txt\`; do
		table=\`echo \${DBTBNG} | sed 's/\\./ /g' | awk '{print \$2}'\`
		engine=\`echo \${DBTBNG} | sed 's/\\./ /g' | awk '{print \$3}'\`
		echo \"        \$engine table: \$table\"
	done
	echo \" \"

	# deprecated method of getting mysql password...
	# get mysql password from defined file, expecting one line, one word, filtering any newlines
	# MYSQL_PASSWORD=\`printf \"%s\" \"\$(< \$MYSQL_PASSWORD_FILE)\"\`
	MYSQL_HUP=\"--defaults-extra-file=\$MYSQL_CNF_FILE --host=\$MYSQL_HOST --port=\$MYSQL_PORT\"
	MYSQL_HUP_PRINT=\"--defaults-extra-file=\$MYSQL_CNF_FILE --host=\$MYSQL_HOST --port=\$MYSQL_PORT\"

	echo \"Checking target MySQL server: \$MYSQL_HUP_PRINT\"
	RESULT=\`mysqlshow \$MYSQL_HUP | grep -v Wildcard | grep -o Databases\`
	if [ \"\$RESULT\" != \"Databases\" ]; then
		echo \"ERROR: Cannot connect to mysql server using: \$MYSQL_HUP_PRINT\"
		exit 1
	fi
	echo \"Mysql connection OK.\"
	echo \" \"

	echo \"READY TO GO ... DUMP TO DB: \$RESTOREDB \$MYSQL_HUP_PRINT\"
	echo \" \"
	read -p \"Press [Enter] to confirm injection of ALL the scheduled files\"
	echo \" \"
	echo \"mysql> CREATE DATABASE IF NOT EXISTS \$RESTOREDB;\"
	mysql \$MYSQL_HUP -e\"CREATE DATABASE IF NOT EXISTS \$RESTOREDB;\"

	RESULT=\`mysqlshow \$MYSQL_HUP | grep -v Wildcard | grep -o \$RESTOREDB | uniq\`
	if [ \"\$RESULT\" != \"\$RESTOREDB\" ]; then
		echo \"Could connect, but could NOT create database: \$RESTOREDB using credentials from: \$MYSQL_CNF_FILE\"
		exit 1
	fi
	echo \"OK. Database \$RESTOREDB is created.\"
	echo \" \"
	" >$restore_file

	# loop all tables in database

	for DBTBNG in $db_table_engine_list; do

		# handle table engine
		#db=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $1}'`
		table=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $2}'`
		engine=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $3}'`

		if [ -z "$TEST_RUN" ]; then
			printf '            Dumping %s table as: %s.sql' $engine $table
		else
			printf '          %s table: %s' $engine $table
		fi

		# some reminders for mysqldump options
		# --skip-dump-date so dump data do NOT differ if table did not really change
		# --single-transaction for properly dumping InnoDB table. This automatically turns off --lock-tables (needed for MyISAM dump)
		# --lock-tables for properly dumping MyISAM table, which anyway is enabled by default
		# --force  Continue even if we get an SQL error.

		# Table Dump includes DROP TABLE IF EXISTS

		# use special flags for InnoDB or MyISAM
		ENGINE_OPT=""
		if [[ $engine == "InnoDB" ]] ;then
			ENGINE_OPT="--single-transaction"
		else
			if [[ $engine == "MyISAM" ]] ;then
				ENGINE_OPT="--lock-tables"
			else
				if [[ $engine == "MEMORY" ]] ;then
					printf ' NOTICE: MEMORY table. '
				else
					printf ' NOTICE: Unexpected engine: NO ENGINE_OPT SET. '
				fi
			fi
		fi

		if [ -z "$TEST_RUN" ]; then

			# dump the table and add lines to restore script

			if [[ $COMPRESSION == "gz" ]] ;then
				printf '.gz ... '
				filedump="$BACKUP_DIR/$db/$db-$table.sql.gz"
				restorefiledump=$(basename $filedump)
				if [ ! -f $filedump ] ;then
					mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | gzip -9 > $filedump
				fi
				echo "
				echo \"Running $restorefiledump ...\"
				zcat $db/$restorefiledump | mysql \$MYSQL_HUP --default-character-set=utf8 \$RESTOREDB" >>$restore_file
			fi

			if [[ $COMPRESSION == "bz2" ]] ;then
				printf '.bz2 ... '
				filedump="$BACKUP_DIR/$db/$db-$table.sql.gz"
				restorefiledump=$(basename $filedump)
				if [ ! -f $filedump ] ;then
					mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | bzip2 -cq9 > $filedump
				fi
				echo "
				echo \"Running $restorefiledump ...\"
				bunzip2 < $db/$restorefiledump | mysql \$MYSQL_HUP --default-character-set=utf8 \$RESTOREDB" >>$restore_file
			fi

			if [[ $COMPRESSION == "none" ]] ;then
				printf ' ... '
				filedump="$BACKUP_DIR/$db/$db-$table.sql"
				restorefiledump=$(basename $filedump)
				if [ ! -f $filedump ] ;then
					mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} > $filedump
				fi
				echo "
				echo \"Running $restorefiledump ...\"
				cat $db/$restorefiledump | mysql \$MYSQL_HUP --default-character-set=utf8 \$RESTOREDB" >>$restore_file
			fi

		fi

		printf '\n'

	done

	# finish restore script
	echo "
		echo \" \"
		echo \"Finished.\"
		echo \" \"
		echo \" \"
		echo \"    Host: \$1\"
		mysqlshow \$MYSQL_HUP \$RESTOREDB
		echo \" \"

	" >>$restore_file

	if [ -z "$TEST_RUN" ]; then
		echo "            RESTORE bash script created: restore-$db.sh"
	fi

	# uncomment the following line if you want to test just dumping the first database on list
	# exit 1;

done

echo " "
echo "Finished."
echo "Remember that I also created some special files: mysql-grants*.sql, mysql-version*.txt and, for each database, the file: restore-*.sh"

exit 0
