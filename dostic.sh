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
    
    ##########
    # BACKUP #
    ##########
    
    # check if given volume contains mysql/mariadb data
    is_db_volume() {
        docker run --rm \
            -v "$1:/mnt:ro" \
            ubuntu:latest \
            /bin/bash -c "[ -d /mnt/mysql ]"
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

    # backup container $1 using mariabackup into restic file "$2.xbstream"
    backup_db() {
        docker exec $1 \
            sh -c 'mariabackup --user root --password "$MYSQL_ROOT_PASSWORD" --backup --stream=xbstream' \
            | \
        docker run \
            -i \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            backup -r "$RESTIC_REPOSITORY" \
            --stdin --stdin-filename "$2.xbstream"
    }

    # clean up repository
    forget() {
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            forget -r "$RESTIC_REPOSITORY" \
            "${RESTIC_FORGET_ARGS[@]}"
    }

    # start backup
    backup() {
        # create arrays containing the first/last volume being backuped for each container
        # used to execute precmd/postcmd only once
        declare -A FIRSTVOL
        declare -A LASTVOL
        for volume in $(docker volume ls -q | grep -vE '^[0-9a-f]{64}$'); do
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
        for volume in $(docker volume ls -q | grep -vE '^[0-9a-f]{64}$'); do
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
            if is_db_volume "$volume"; then
                echo "Detected database volume"
                
                # exit if database volume belongs to multiple containers (for whatever reason)
                verify_container_count "$containers"
                backup_db "$containers" "$volume"
            else
                backup_volume "$volume" "$volume"
            fi
            
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

        for dir in "${BACKUP_DIRS[@]}"; do
            echo "Backup $dir"
            backup_volume "$dir" "${dir:1}"
        done

        # clean up repository once a week
        if [ $(date +%u) == 7 ]; then
            echo "Forget"
            forget
        fi
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

    # restore restic snapshot $1 of mariabackup stream "$2.xbstream" using $3 docker image into volume $4
    restore_db() {
        # copy and extract backup
        docker run \
            "${RESTIC_DOCKER_PARAMS[@]}" \
            dump "$1" -r "$RESTIC_REPOSITORY"  \
            "/$2.xbstream" \
            | \
        docker run \
            -i --rm \
            -v "$4:/var/lib/mysql" \
            --entrypoint "/usr/bin/mbstream" \
            "$3" \
            -x -C "/var/lib/mysql"
        
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
        echo "./dostic.sh backup"
        echo 
        echo 
        echo "Restore regular data volume:"
        echo "./dostic.sh restore_volume <snapshot> <restic-directory> <volume-or-directory>"
        echo
        echo "Restore MariaDB volume:"
        echo "./dostic.sh restore_db <snapshot> <restic-xbstream> <mariadb-image> <volume-or-directory>"
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
        backup
        ;;
    "restore_volume")
        if [ "$#" != 4 ]; then 
            print_help
            exit 1
        fi
        shift
        restore_volume "$@"
        ;;
    "restore_db")
        if [ "$#" != 5 ]; then 
            print_help
            exit 1
        fi
        shift
        restore_db "$@"
        ;;
    "list")
        run "snapshots"
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
