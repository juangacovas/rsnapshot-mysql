# rsnapshot-mysql

This is a rsnapshot friendly tool that allows to pull all MySQL databases from a host, creating One File Per Table and a convenient restore script

Features:
  - Handle dumps from local or remote MySQL hosts.
  - Allows to choose compression type for dumps (none, gzip or bzip2).
  - Automatically fetches database names from mysql host and creates a directory for each database.
  - Dump each table to its own file (.sql, .sql.gz or .sql.bz2) under a directory named as the database.
  - Handle dump of mixed database tables using MyISAM AND/OR InnoDB...
  - Ready to work with "backup_script" feature of rsnapshot, an incremental snapshot utility for local and remote filesystems.
  - Creates a convenient restore script (BASH) for each database, under each dump directory.
  - Creates backup of GRANTs (mysql permissions), and info files with the list of tables and mysql version.
