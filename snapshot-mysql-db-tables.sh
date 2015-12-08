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

ROOT_BACKUP_DIR="/backup"
BACKUP_DIR="/backup/databases"

TIMESTAMP=$(date +"%Y-%m-%d-%H.%M")
MYSQL_USER="root"
MYSQL_PASSWORD_FILE="/home/ddadmin/sysadmin/mysql-root.txt"
MYSQL_PASSWORD=`cat $MYSQL_PASSWORD_FILE`

echo " "
echo "Getting database list"

databaselist=`mysql --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash -e "SHOW DATABASES;" | grep -Ev "(^mysql$|^phpmyadmin$|^Database$|information_schema|performance_schema|^test_|_test$|_bak$|^bak_)"`
# loop all database names
for db in $databaselist; do

        # exclude system databases
        if [ $db != "mysql" ] && [ $db != "phpmyadmin" ] ;then

                printf 'Dumping DB: %s ... ' $db

								# get a list of db.table.engine
                db_table_engine_list=`mysql --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name,'.',engine) FROM information_schema.tables WHERE table_schema = '${db}'"`
                db_table_list=`mysql --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name) FROM information_schema.tables WHERE table_schema = '${db}'"`

                mkdir -p $BACKUP_DIR/$db
                echo $db_table_list > $BACKUP_DIR/$db/$db-tablelist.txt

                for DBTBNG in $db_table_engine_list; do
                        #db=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $1}'`
                        table=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $2}'`
                        engine=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $3}'`
                        
                        # echo " Dumping: $db/$table.sql"

												# --skip-dump-date so dump data do NOT differ if table did not really change
                      	# --single-transaction for properly dumping InnoDB table. This automatically turns off --lock-tables (needed for MyISAM dump)
                      	# --lock-tables for properly dumping MyISAM table, which anyway is enabled by default
                      	# --force  Continue even if we get an SQL error.

												# Table Dump includes DROP TABLE IF EXIST

                        if [ $engine == "InnoDB" ] ;then
                        	mysqldump --user=$MYSQL_USER -p$MYSQL_PASSWORD --hex-blob --force --single-transaction --skip-dump-date ${db} ${table} | gzip -9 > $BACKUP_DIR/$db/$db-$table.sql.gz
                        else
	                        if [ $engine == "MyISAM" ] ;then
	                        	mysqldump --user=$MYSQL_USER -p$MYSQL_PASSWORD --hex-blob --force --lock-tables --skip-dump-date ${db} ${table} | gzip -9 > $BACKUP_DIR/$db/$db-$table.sql.gz
	                        else
	                        	printf "ERROR: Unexpected table engine: [$engine].\n"
	                        fi                        
                        fi
                                                
                        # TODO create restore script
                done

                printf '%s\n' $BACKUP_DIR/$db

        fi
done

echo " "
echo "Dumping grants to $BACKUP_DIR/mysqlGrants.sql"
mysql --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | mysql --user=$MYSQL_USER -p$MYSQL_PASSWORD --no-auto-rehash --skip-column-names | sed 's/$/;/g' > $BACKUP_DIR/mysqlGrants.sql

echo "Finished."

