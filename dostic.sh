#!/bin/bash

# https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# check requirements
if [ ! -s "$DIR/dostic.conf" ]; then
    echo "Please copy config file dostic.conf.example to dostic.conf and adjust settings!"
    exit 1
elif [ ! -s "$DIR/restic_password" ]; then
    echo "Please set password for restic repository in file 'restic_password'!"
    exit 1
fi

. "$DIR/dostic.conf"

# Parameters passed to docker run
RESTIC_DOCKER_PARAMS=( \
    --rm \
    -e "RESTIC_PASSWORD_FILE=/restic_password" \
    --hostname "$RESTIC_HOSTNAME" \
    --network "$DOCKER_NETWORK" \
    -v "$RESTIC_CACHE_VOLUME:/root/.cache" \
    -v "$RESTIC_PASSWORD_FILE:/restic_password" \
    -v "$RCLONE_CONFIG:/config" \
    "$DOCKER_IMAGE" \
    --verbose
)

docker build --pull -t "$DOCKER_IMAGE" "$DIR/restic-rclone" > /dev/null

# create dedicated backup network for ipv6 support
docker network create --driver bridge --subnet "$DOCKER_IPV6_SUBNET" --ipv6 "$DOCKER_NETWORK" > /dev/null

(
    set -e
    set -o pipefail
    
    ##########
    # BACKUP #
    ##########
    
    detect_volume() {
        docker run --rm \
            -v "$1:/mnt:ro" \
            ubuntu:latest \
            /bin/bash -c "( [ -d /mnt/mysql ] && echo mariadb ) || ( [ -f /mnt/storage.bson ] && echo mongodb ) || exit 0"
    }

    # output associated containers of given volume
    get_containers_of_volume() {
        docker ps \
            --format '{{.Names}}' \
            --filter "volume=$1"
    }

    # exit if given list of containers is longer than 1
    verify_container_count() {
        if [ $(echo "$1" | wc -l) != 1 ]; then
            echo "Error: Number of associated containers isn't 1!"
            exit 1
        fi
    }

    # output pre command label of given container
    get_precmd_of_container() {
        docker inspect "$1" --format '{{index .Config.Labels "dostic.precmd"}}'
    }
    # output post command label of given container
    get_postcmd_of_container() {
        docker inspect "$1" --format '{{index .Config.Labels "dostic.postcmd"}}'
    }

    # backup volume $1 into restic directory "/backup/$2"
    backup_volume() {
        docker run \
            -v "$1:/backup/$2:ro" \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            backup -r "$RESTIC_REPOSITORY"  \
            --exclude-if-present .nobackup "/backup/$2"
    }

    # backup container $1 using mariabackup into compressed restic file "$2.xbstream.gz"
    backup_mariadb() {
        docker exec $1 \
            sh -c 'mariabackup --user root --password "$MYSQL_ROOT_PASSWORD" --backup --stream=xbstream | gzip -c --rsyncable -9' \
            | \
        docker run \
            -i \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            backup -r "$RESTIC_REPOSITORY" \
            --stdin --stdin-filename "$2.xbstream.gz"
    }

    # backup container $1 using mongodump into compressed restic file "$2.mdb.gz"
    backup_mongodb() {
        docker exec $1 \
            sh -c 'mongodump --archive | gzip -c --rsyncable -9 -' \
            | \
        docker run \
            -i \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            backup -r "$RESTIC_REPOSITORY" \
            --stdin --stdin-filename "$2.mdb.gz"
    }

    # clean up repository
    forget() {
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            forget -r "$RESTIC_REPOSITORY" \
            "${RESTIC_FORGET_ARGS[@]}"
    }

    # start backup of volumes $1
    backup() {
        # create arrays containing the first/last volume being backuped for each container
        # used to execute precmd/postcmd only once
        declare -A FIRSTVOL
        declare -A LASTVOL
        for volume in $1; do
            if [[ "$volume" == "$RESTIC_CACHE_VOLUME" ]]; then
                continue
            fi
            
            containers=$(get_containers_of_volume "$volume")
            
            # execute pre backup commands
            while read -r container && test "$container"; do
                if [ ! ${FIRSTVOL[$container]+_} ]; then
                    FIRSTVOL[$container]="$volume"
                fi
                LASTVOL[$container]="$volume"
            done <<< "$containers"
        done
            
        # backup each named volume
        for volume in $1; do
            echo "Volume: $volume"
            
            if [[ "$volume" == "$RESTIC_CACHE_VOLUME" ]]; then
                echo "Skip restic_cache";
                continue
            fi
            
            containers=$(get_containers_of_volume "$volume")
            echo "Containers:"
            echo "$containers"
            
            # execute pre backup commands
            while read -r container && test "$container"; do
                # execute command only the first time
                if [ "$volume" != "${FIRSTVOL[$container]}" ]; then
                    continue;
                fi
                
                cmd=$(get_precmd_of_container "$container")
                # convert command string to bash array
                # eval should be safe here, because setting docker labels requires root anyway
                eval "cmd=($cmd)"
                if test "$cmd"; then
                    echo "Execute pre backup command: ${cmd[@]}"
                    docker exec "$container" "${cmd[@]}"
                fi
            done <<< "$containers"
            
            # backup
            case $(detect_volume "$volume") in
                "mariadb")
                    echo "Detected mariadb volume"
                    
                    # exit if database volume belongs to multiple containers (for whatever reason)
                    verify_container_count "$containers"
                    backup_mariadb "$containers" "$volume"
                    ;;
                "mongodb")
                    echo "Detected mongodb volume"
                    
                    # exit if database volume belongs to multiple containers (for whatever reason)
                    verify_container_count "$containers"
                    backup_mongodb "$containers" "$volume"
                    ;;
                *)
                    backup_volume "$volume" "$volume"
                    ;;
            esac
            
            # execute post backup commands
            while read -r container && test "$container"; do
                # execute command only the last time
                if [ "$volume" != "${LASTVOL[$container]}" ]; then
                    continue;
                fi
                
                cmd=$(get_postcmd_of_container "$container")
                # convert command string to bash array
                # eval should be safe here, because setting docker labels requires root anyway
                eval "cmd=($cmd)"
                if test "$cmd"; then
                    echo "Execute post backup command: ${cmd[@]}"
                    docker exec "$container" "${cmd[@]}"
                fi
            done <<< "$containers"
            
            echo "======================================================================="
        done
    }
    
    ###########
    # RESTORE #
    ###########

    # run restic container and pass parameters
    run() {
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            "$@" -r "$RESTIC_REPOSITORY"
    }

    # restore restic snapshot $1 of directory "/backup/$2" into volume $3
    restore_volume() {
        docker run \
            -v "$3:/backup/$2" \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            restore "$1" -r "$RESTIC_REPOSITORY"  \
            --target "/" --path "/backup/$2"
    }

    # restore restic snapshot $1 of mariabackup stream "$2.xbstream.gz" using $3 docker image into volume $4
    restore_mariadb() {
        # copy and extract backup
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            dump "$1" -r "$RESTIC_REPOSITORY"  \
            "/$2.xbstream.gz" \
            | \
        docker run \
            -i --rm \
            -v "$4:/var/lib/mysql" \
            --entrypoint "/bin/bash" \
            "$3" \
            -c 'gzip -c -d - | mbstream -x -C "/var/lib/mysql"'
        
        # prepare backup
        docker run \
            --rm \
            -v "$4:/var/lib/mysql" \
            --entrypoint "/usr/bin/mariabackup" \
            "$3" \
            --prepare --target-dir "/var/lib/mysql"
        
        # fix perm
        docker run \
            --rm \
            -v "$4:/var/lib/mysql" \
            --entrypoint "/bin/chown" \
            "$3" \
            -R 999:999 "/var/lib/mysql"
        docker run \
            --rm \
            -v "$4:/var/lib/mysql" \
            --entrypoint "/bin/chmod" \
            "$3" \
            -R g+w "/var/lib/mysql"
    }

    # restore restic snapshot $1 of mongodb stream "$2.mdb.gz" using $3 docker image into volume $4
    restore_mongodb() {
        # start mongodb instance
        containerid=$(docker run \
            -d --rm \
            -v "$4:/data/db" \
            "$3")
        
        sleep 5
        
        # copy and extract backup
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            dump "$1" -r "$RESTIC_REPOSITORY"  \
            "/$2.mdb.gz" \
            | \
        docker exec \
            -i \
            "$containerid" \
            "/bin/bash" \
            -c 'gzip -c -d - | mongorestore --archive'

        # stop mongodb instance
        docker stop "$containerid"
    }
    
    #########
    # TOOLS #
    #########
    
    # init repository
    init() {
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            init -r "$RESTIC_REPOSITORY"
    }

    # configure rclone
    configure() {
        docker run \
            -it \
            --entrypoint /usr/bin/rclone \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            config
    }
    
    print_help() {
        echo "Dostic: Docker volume backup and restore script using Restic"
        echo
        echo "Configure rclone:"
        echo "./dostic.sh configure"
        echo 
        echo "Init restic repository:"
        echo "./dostic.sh init"
        echo 
        echo 
        echo "Start backup:"
        echo "./dostic.sh backup [<volume>]"
        echo 
        echo 
        echo "Restore regular data volume:"
        echo "./dostic.sh restore_volume <snapshot> <restic-directory> <volume-or-directory>"
        echo
        echo "Restore MariaDB volume:"
        echo "./dostic.sh restore_mariadb <snapshot> <restic-xbstream> <mariadb-image> <volume-or-directory>"
        echo
        echo "Restore MongoDB volume:"
        echo "./dostic.sh restore_mongodb <snapshot> <restic-mdb> <mongodb-image> <volume-or-directory>"
        echo
        echo 
        echo "List all restic snapshots:"
        echo "./dostic.sh list"
        echo 
        echo "Execute restic with given parameters:"
        echo "./dostic.sh exec <param>..."
    }
    
    case "$1" in
    "configure")
        configure
        ;;
    "init")
        init
        ;;
    "backup")
        if [ "$#" == 1 ]; then
            # backup each named volume
            backup "$(docker volume ls -q | grep -vE '^[0-9a-f]{64}$')"
            
            # backup directories
            for dir in "${BACKUP_DIRS[@]}"; do
                echo "Backup $dir"
                backup_volume "$dir" "${dir:1}"
            done

            # clean up repository once a week
            if [ $(date +%u) == 7 ]; then
                echo "Forget"
                forget
            fi
        else
            backup "$2"
        fi
        ;;
    "restore_volume")
        if [ "$#" != 4 ]; then 
            print_help
            exit 1
        fi
        shift
        restore_volume "$@"
        ;;
    "restore_mariadb")
        if [ "$#" != 5 ]; then
            print_help
            exit 1
        fi
        shift
        restore_mariadb "$@"
        ;;
    "restore_mongodb")
        if [ "$#" != 5 ]; then 
            print_help
            exit 1
        fi
        shift
        restore_mongodb "$@"
        ;;
    "list")
        run "snapshots" --group-by paths
        ;;
    "exec")
        shift
        run "$@"
        ;;
    *)
        print_help
        ;;
    esac
)

ret=$?

[ $ret == 0 ] && echo "Success" || echo "FAILED"

docker network rm "$DOCKER_NETWORK" > /dev/null

exit $ret
