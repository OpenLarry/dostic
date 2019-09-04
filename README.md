Dostic: [Docker](https://www.docker.com/) volume backup and restore script using [Restic](https://restic.net/)
==============================================================================================================
*Dostic* lets you backup all named Docker volumes into a restic repository and helps you to restore from it. It detects [MariaDB](https://mariadb.org/) and [MongoDB](https://www.mongodb.com/) volumes automatically and performs hot online backups using [Mariabackup](https://mariadb.com/kb/en/library/mariabackup-overview/) and [mongodump](https://docs.mongodb.com/manual/reference/program/mongodump/).

Preparation
-----------

* Put password for restic repository in a file called `restic_password`.
* Copy `dostic.conf.example` to `dostic.conf` and adjust settings.
* If you want to use [Rclone](https://rclone.org/) backend in restic, you should start the configuration wizard:
  
  `./dostic.sh configure`
* Initialize restic repository and test connection:
  
  `./dostic.sh init`

Backup
------

* Run:
  `./dostic.sh backup`

Restore
-------

* List all restic snapshots:
  
  `./dostic.sh list`

* Restore regular data volume:
  
  `./dostic.sh restore_volume <snapshot> <restic-directory> <volume-or-directory>`

* Restore MariaDB volume:
  
  `./dostic.sh restore_mariadb <snapshot> <restic-xbstream> <mariadb-image> <volume-or-directory>`

* Restore MongoDB volume:
  
  `./dostic.sh restore_mongodb <snapshot> <restic-mdb> <mongo-image> <volume-or-directory>`

Examples
--------

* Backup all named Docker volumes (and host directories specified in `BACKUP_DIRS`):
  - Just execute:
    
    `./dostic.sh backup`

* Restore regular volume named `my_data`:
  - Create a new volume:
    
    `docker create volume restored_data`
  - Restore data from latest snapshot:
    
    `./dostic.sh restore_volume latest my_data restored_data`

* Restore MariaDB data volume named `my_database`:
  - Create a new volume:
    
    `docker create volume restored_database`
  - Restore data from latest snapshot using MariaDB 10.3 Docker image:
    
    `./dostic.sh restore_mariadb latest my_database mariadb:10.3 restored_database`

Miscellaneous
-------------

* The content of container labels `dostic.precmd` and `dostic.postcmd` is executed using `docker exec` before and after backup of associated volumes. E.g. add `dostic.precmd=redis-cli save` to a redis container to ensure all data is written to disk before starting the backup.
* `restic forget` is executed on sundays automatically using parameters provided in `RESTIC_FORGET_ARGS`.
* Directories containing a file `.nobackup` are ignored.
