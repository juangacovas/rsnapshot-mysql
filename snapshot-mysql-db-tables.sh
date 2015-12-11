#!/bin/bash
############################################################################################################################################################################
#
# Dump all mysql databases, one file per table
#
#   By Juanga Covas 2015 for WPC7.com
#
#   with tips from http://dba.stackexchange.com/questions/20/how-can-i-optimize-a-mysqldump-of-a-large-database
#
############################################################################################################################################################################

BACKUP_DIR="./mysqldumps"

TIMESTAMP=$(date +"%Y-%m-%d-%H.%M")

echo "-----------------------------------------------------------------------------------------"
echo "snapshot-mysql-db-tables.sh    by Juanga Covas 2015"
echo " "

if [ -z $2 ] ;then
	echo " "
	echo "Required parameters: dbhost        compression   [test]"
	echo "            Example: my.db.server  none|gz|bz2   test"
	echo " "
	echo "Will try to connect with user: remotebackup  password: /root/snapshot-db-pwd.txt"
	exit 1;
fi

MYSQL_HOST=$1
COMPRESSION=$2
TEST_RUN=$3

MYSQL_USER="remotebackup"
MYSQL_PASSWORD_FILE="/root/snapshot-db-pwd.txt"
if [ ! -f $MYSQL_PASSWORD_FILE ] ;then 
	echo "Cannot read: $MYSQL_PASSWORD_FILE"
	exit 1
fi
if [ ! -s $MYSQL_PASSWORD_FILE ] ;then
	echo "File is empty: $MYSQL_PASSWORD_FILE"
	exit 1
fi
MYSQL_PASSWORD=`cat $MYSQL_PASSWORD_FILE`
MYSQL_HUP="--host=$MYSQL_HOST --user=$MYSQL_USER -p$MYSQL_PASSWORD"
MYSQL_DUMP_FLAGS="--compress --hex-blob --force --single-transaction --skip-dump-date"

echo "Will try to dump databases from: $MYSQL_HOST to: $BACKUP_DIR"
echo " "
if [ ! -z "$TEST_RUN" ]; then
	echo "(TEST RUN) Will NOT dump anything."
	echo " "
fi

if [ $COMPRESSION == "gz" ] ;then
	echo "Compress to .sql.gz (gzip)"
else
	if [ $COMPRESSION == "bz2" ] ;then
		echo "Compress to .sql.bz2 (bzip2)"
	else
		if [ $COMPRESSION == "none" ] ;then
			echo "No compression: .sql"
		else
			echo "ERROR: valid compression parameter is none|gz|bz2"
			exit 1;
		fi
	fi
fi

mkdir -p $BACKUP_DIR

echo " "
printf 'Testing connection to MySQL ... '

RESULT=`mysqlshow $MYSQL_HUP | grep -v Wildcard | grep -o Databases`
if [ "$RESULT" == "Databases" ]; then
	printf "OK.\n"
else
	printf "ERROR: Cannot connect to MySQL server. Aborting.\n\n"
	exit 1;
fi

echo " "
echo "MySQL version info"
if [ -z "$TEST_RUN" ]; then
	mysql $MYSQL_HUP --skip-column-names -e"SHOW VARIABLES LIKE '%version%';" > $BACKUP_DIR/mysql-version-$MYSQL_HOST.txt
fi
mysql $MYSQL_HUP --skip-column-names -e"SHOW VARIABLES LIKE '%version%';"
echo " "

if [ -z "$TEST_RUN" ]; then
	echo "Dumping GRANTs to $BACKUP_DIR/mysql-grants-$MYSQL_HOST.sql"
	mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | mysql --host=$MYSQL_HOST --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names | sed 's/$/;/g' > $BACKUP_DIR/mysql-grants-$MYSQL_HOST.sql
else
	echo "(TEST RUN) Skipping GRANTs dump"
fi
echo " "

echo "Getting database list to dump ... "
echo " "

databaselist=`mysql $MYSQL_HUP --no-auto-rehash -e "SHOW DATABASES;" | grep -Ev "(^mysql$|^phpmyadmin$|^Database$|information_schema|performance_schema|^test_|_test$|_bak$|^bak_)"`

# loop all database names
for db in $databaselist; do

	# exclude system databases
	if [ $db == "mysql" ] || [ $db == "phpmyadmin" ] ;then
		continue
	fi

	if [ ! -z "$TEST_RUN" ]; then
		printf 'Found DB: %s \n' $db
	else
		printf 'Dumping DB: %s \n' $db
	fi

	# get a list of db.table.engine
	db_table_engine_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name,'.',engine) FROM information_schema.tables WHERE table_schema = '${db}'"`
	db_table_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name) FROM information_schema.tables WHERE table_schema = '${db}'"`

	mkdir -p $BACKUP_DIR/$db
	if [ -z "$TEST_RUN" ]; then
		echo $db_table_list > $BACKUP_DIR/$db/$db-tablelist.txt
	fi

	restore_file="$BACKUP_DIR/$db/restore-$db.sh"
	dbr="${db}_restored"
	
	echo "#!/bin/bash

	#########################################################################
	#
	#	Database Restore script for backup:
	#
	#	from host: $MYSQL_HOST
	#		   db: $db
	#		 date: $TIMESTAMP
	#
	#########################################################################


	RESTOREDB=\"$dbr\"

	# checks
	
    if [ \"\$BASH\" != \"/bin/bash\" ] ;then
            echo \"Please execute the script using /bin/bash\"
            exit 1;
    fi
	if [ -z \"\$1\" ] ;then
		echo \"Expecting target mysql host as parameter\"
		exit 1
	fi
    if ls $db*.sql* 1> /dev/null 2>&1; then
            echo \"File check OK\"
    else
            echo \"Cannot find $db.sql* files. Please execute the script under its directory.\"
            exit 1
    fi

	echo \" \"
	echo \"Database Restore script for backup:\"	
	echo \" \"
	echo \"      from host: $MYSQL_HOST\"
	echo \"             db: $db\"
	echo \"           date: $TIMESTAMP\"
	echo \" \"
	echo \"RESTORE TO HOST: \$1\"
	echo \"  RESTORE TO DB: \$RESTOREDB\"
	echo \" \"
	
	MYSQL_HOST=\$1
	MYSQL_USER=\"remotebackup\"
	MYSQL_PASSWORD_FILE=\"/root/snapshot-db-pwd.txt\"
	if [ ! -f \$MYSQL_PASSWORD_FILE ] ;then 
		echo \"Cannot read: \$MYSQL_PASSWORD_FILE\"
		exit 1
	fi
	if [ ! -s \$MYSQL_PASSWORD_FILE ] ;then
		echo \"File is empty: \$MYSQL_PASSWORD_FILE\"
		exit 1
	fi
	MYSQL_PASSWORD=\`cat \$MYSQL_PASSWORD_FILE\`
	MYSQL_HUP=\"--host=\$MYSQL_HOST --user=\$MYSQL_USER -p\$MYSQL_PASSWORD\"
	MYSQL_HUP_PRINT=\"--host=\$MYSQL_HOST --user=\$MYSQL_USER -p...\"

	echo \"Checking host \$1 ...\"
	RESULT=\`mysqlshow \$MYSQL_HUP | grep -v Wildcard | grep -o Databases\`
	if [ \"\$RESULT\" != \"Databases\" ]; then
		echo \"ERROR: Cannot connect to mysql server using: \$MYSQL_HUP_PRINT\"
		exit 1
	fi
	echo \"Mysql connection OK.\"

	echo \"mysql> CREATE DATABASE IF NOT EXISTS \$RESTOREDB;\"
	mysql \$MYSQL_HUP -e\"CREATE DATABASE IF NOT EXISTS \$RESTOREDB;\"

	RESULT=\`mysqlshow \$MYSQL_HUP | grep -v Wildcard | grep -o \$RESTOREDB\`
	if [ \"\$RESULT\" != \"\$RESTOREDB\" ]; then
		echo \"Could connect, but could NOT create database: \$RESTOREDB using user: \$MYSQL_USER\"
		exit 1
	fi
	echo \"Database \$RESTOREDB seems there.\"
	echo \" \"

	echo \"READY TO GO ... DUMP TO DB: \$RESTOREDB \$MYSQL_HUP_PRINT\"
	echo \" \"
	read -p \"Press [Enter] to confirm dumping ALL .sql* files\"
	echo \" \"
	" >$restore_file

	for DBTBNG in $db_table_engine_list; do

		#db=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $1}'`
		table=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $2}'`
		engine=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $3}'`

		if [ -z "$TEST_RUN" ]; then
			printf '        Dumping %s table as: %s.sql' $engine $table
		else
			printf '          %s table: %s' $engine $table
		fi

		# --skip-dump-date so dump data do NOT differ if table did not really change
		# --single-transaction for properly dumping InnoDB table. This automatically turns off --lock-tables (needed for MyISAM dump)
		# --lock-tables for properly dumping MyISAM table, which anyway is enabled by default
		# --force  Continue even if we get an SQL error.

		# Table Dump includes DROP TABLE IF EXISTS

		if [ $engine == "InnoDB" ] ;then
			ENGINE_OPT="--single-transaction"
		else
			if [ $engine == "MyISAM" ] ;then
				ENGINE_OPT="--lock-tables"
			else
				printf "ERROR: Unexpected table engine: [$engine].\n"
			fi
		fi

		if [ -z "$TEST_RUN" ]; then
		
			if [ $COMPRESSION == "gz" ] ;then
				printf '.gz ... '
				filedump="$BACKUP_DIR/$db/$db-$table.sql.gz"
				restorefiledump=$(basename $filedump)
				mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | gzip -9 > $filedump
				echo "
				echo \"Dumping $restorefiledump ...\"
				zcat $restorefiledump | mysql \$MYSQL_HUP --default-character-set=utf8 \$RESTOREDB" >>$restore_file
			fi
			
			if [ $COMPRESSION == "bz2" ] ;then
				printf '.bz2 ... '
				filedump="$BACKUP_DIR/$db/$db-$table.sql.gz"
				restorefiledump=$(basename $filedump)
				mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | bzip2 -cq9 > $filedump
				echo "
				echo \"Dumping $restorefiledump ...\"
				bunzip2 < $restorefiledump | mysql \$MYSQL_HUP --default-character-set=utf8 \$RESTOREDB" >>$restore_file
			fi
			
			if [ $COMPRESSION == "none" ] ;then
				printf ' ... '
				filedump="$BACKUP_DIR/$db/$db-$table.sql"
				restorefiledump=$(basename $filedump)
				mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} > $filedump
				echo "
				echo \"Dumping $restorefiledump ...\"
				cat $restorefiledump | mysql \$MYSQL_HUP --default-character-set=utf8 \$RESTOREDB" >>$restore_file
			fi

		fi

		printf '\n'

		#TODO create restore script
		
	done

	echo "
		echo \" \"
		echo \"Finished.\"
		echo \" \"
		echo \" \"
		mysqlshow \$MYSQL_HUP \$RESTOREDB
		echo \" \"
		
	" >>$restore_file

	exit 0

	#printf '%s\n' $BACKUP_DIR/$db

done

echo " "
echo "Finished."

exit 0
