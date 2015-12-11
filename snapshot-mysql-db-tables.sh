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
mkdir -p $BACKUP_DIR

TIMESTAMP=$(date +"%Y-%m-%d-%H.%M")

if [ -z $2 ] ;then
	echo "Required parameters: dbhost  compression"
	echo "            Example: my.db.server none|gz|bz2"
	echo " "
	echo "Will try to connect with user: remotebackup  password: /root/snapshot-db-pwd.txt"
        exit 1;
fi

MYSQL_HOST=$1
COMPRESSION=$2

MYSQL_USER="remotebackup"
MYSQL_PASSWORD_FILE="/root/snapshot-db-pwd.txt"
MYSQL_PASSWORD=`cat $MYSQL_PASSWORD_FILE`
MYSQL_HUP="--host=$MYSQL_HOST --user=$MYSQL_USER -p$MYSQL_PASSWORD"
MYSQL_DUMP_FLAGS="--compress --hex-blob --force --single-transaction --skip-dump-date"

echo "-------------------------------------------------------------------------------"
echo "Will try to dump databases from $MYSQL_HOST ..."
echo " "

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

printf 'MySQL connection test ... '

RESULT=`mysqlshow $MYSQL_HUP | grep -v Wildcard | grep -o Databases`
if [ "$RESULT" == "Databases" ]; then
	printf "OK.\n"
else
	printf "ERROR: Cannot connect to MySQL server. Aborting.\n\n"
	exit 1;
fi

echo "Getting database list ..."

databaselist=`mysql $MYSQL_HUP --no-auto-rehash -e "SHOW DATABASES;" | grep -Ev "(^mysql$|^phpmyadmin$|^Database$|information_schema|performance_schema|^test_|_test$|_bak$|^bak_)"`

# loop all database names
for db in $databaselist; do

        # exclude system databases
        if [ $db != "mysql" ] && [ $db != "phpmyadmin" ] ;then

                printf 'Dumping DB: %s \n' $db

		# get a list of db.table.engine
                db_table_engine_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name,'.',engine) FROM information_schema.tables WHERE table_schema = '${db}'"`
                db_table_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name) FROM information_schema.tables WHERE table_schema = '${db}'"`

                mkdir -p $BACKUP_DIR/$db
                echo $db_table_list > $BACKUP_DIR/$db/$db-tablelist.txt

                for DBTBNG in $db_table_engine_list; do
                        #db=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $1}'`
                        table=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $2}'`
                        engine=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $3}'`

                        printf '        Dumping %s table: %s.sql' $engine $table

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

			if [ $COMPRESSION == "gz" ] ;then
				printf '.gz ... '
	 			mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | gzip -9 > $BACKUP_DIR/$db/$db-$table.sql.gz
			fi
                        if [ $COMPRESSION == "bz2" ] ;then
				printf '.bz2 ... '
	                        mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | bzip2 -cq9 > $BACKUP_DIR/$db/$db-$table.sql.bz2
			fi
                        if [ $COMPRESSION == "none" ] ;then
				printf ' ... '
                                mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} > $BACKUP_DIR/$db/$db-$table.sql
			fi

			printf '\n'

                        # TODO create restore script
                done

                #printf '%s\n' $BACKUP_DIR/$db

        fi
done

echo " "
echo "Dumping grants to $BACKUP_DIR/mysqlGrants-$MYSQL_HOST.sql"
mysql --host=$MYSQL_HOST --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | mysql --host=$MYSQL_HOST --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names | sed 's/$/;/g' > $BACKUP_DIR/mysqlGrants-$MYSQL_HOST.sql

echo "Finished."

exit 0
