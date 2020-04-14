#!/usr/bin/env bash

INSTALL_PATH="/opt/ocariot-swarm"
source ${INSTALL_PATH}/scripts/general_functions.sh

set_variables_environment "${ENV_OCARIOT}"
set_variables_environment "${ENV_MONITOR}"

remove_backup_container &> /dev/null

VALIDATING_OPTS=$(echo "$@" | sed 's/ /\n/g' |
	grep -P "(\-\-services|\-\-time|\-\-expression|\-\-keys).*" -v | grep '\-\-')

CHECK_NAME_SERVICE_OPT=$(echo "$@" | grep -wo '\-\-services')
SERVICES=$(echo "$@" | grep -o -P '(?<=--services ).*' | sed "s/--.*//g")

CHECK_TIME_OPT=$(echo "$@" | grep -wo '\-\-time')
RESTORE_TIME=$(echo "$@" | grep -o -P '(?<=--time ).*' | sed 's/--.*//g')

CHECK_AUTO_BKP_OPT=$(echo "$@" | grep -wo '\-\-expression')
EXPRESSION_BKP=$(echo "$@" | grep -o -P '(?<=--expression ).*' | sed 's/--.*//g')

if ([ "$1" != "backup" ] && [ "$1" != "restore" ]) ||
	([ "$2" != "--services" ] && [ "$2" != "--time" ] && [ "$2" != "--keys" ] &&
		[ "$2" != "--expression" ] && [ "$2" != "" ]) ||
	[ ${VALIDATING_OPTS} ] ||
	([ ${CHECK_NAME_SERVICE_OPT} ] && [ -z "${SERVICES}" ]) ||
	([ ${CHECK_AUTO_BKP_OPT} ] && [ -z "${EXPRESSION_BKP}" ]) ||
	([ ${CHECK_TIME_OPT} ] && [ "$(echo ${RESTORE_TIME} | wc -w)" != 1 ]); then
	monitor_help
fi

if ([ $1 = "backup" ] && [ ${CHECK_TIME_OPT} ]) ||
	([ $1 = "restore" ] && [ ${CHECK_AUTO_BKP_OPT} ]); then
	monitor_help
fi

check_backup_target_config

if [ ${RESTORE_TIME} ]; then
	RESTORE_TIME="--time ${RESTORE_TIME}"
fi

COMMAND="backupFull"
BACKUP_VOLUME_PROPERTY=""
SOURCE_VOLUME_PROPERTY=":ro"

if [ "$1" = "restore" ]; then
	COMMAND="restore ${RESTORE_TIME}"
	BACKUP_VOLUME_PROPERTY=":ro"
	SOURCE_VOLUME_PROPERTY=""
	
	check_restore_target_config
fi

if [ ${CHECK_AUTO_BKP_OPT} ]; then

	CRONTAB_COMMAND="${EXPRESSION_BKP} ${INSTALL_PATH}/ocariot monitor backup ${CHECK_NAME_SERVICE_OPT} ${SERVICES} >> /tmp/ocariot_monitor_backup.log"

	STATUS=$(check_crontab "${CRONTAB_COMMAND}")

	if [ "${STATUS}" = "enable" ]; then
		crontab -u ${USER} -l
		echo "Backup is already scheduled"
		exit
	fi
	(
		crontab -u ${USER} -l
		echo "${CRONTAB_COMMAND}"
	) | crontab -u ${USER} -

	STATUS=$(check_crontab "${CRONTAB_COMMAND}")

	if [ "${STATUS}" = "enable" ]; then
		crontab -u ${USER} -l
		echo "Backup schedule successful!"
	else
		echo "Unsuccessful backup schedule!"
	fi

	exit
fi

VOLUMES_BKP=""
RUNNING_SERVICES=""

MONITOR_VOLUMES=$(cat ${INSTALL_PATH}/docker-monitor-stack.yml | grep -P "name: ocariot.*data" | sed 's/\(name:\| \)//g')
EXPRESSION_GREP=$(echo "${MONITOR_VOLUMES}" | sed 's/ /|/g')

# Verifying if backup exist
if [ "$1" = "restore" ] && [ "${RESTORE_TARGET}" = "LOCAL" ]; then
	DIRECTORIES=$(ls ${LOCAL_TARGET} 2>/dev/null)
	if [ $? -ne 0 ]; then
		echo "Directory ${LOCAL_TARGET} not found."
		exit
	fi

	EXIST_BKP=false
	for DIRECTORY in ${DIRECTORIES}; do
		if [ "$(echo "${MONITOR_VOLUMES}" | grep -w "${DIRECTORY}")" ]; then
			EXIST_BKP=true
			break
		fi
	done

	if ! ${EXIST_BKP}; then
		echo "No container backup was found"
		exit
	fi
fi

VOLUME_COMMAND="list --verbosity=9"

if [ -z "${SERVICES}" ]; then
	if [ "$1" = "restore" ] && [ "${RESTORE_TARGET}" = "LOCAL" ]; then
		SERVICES=$(ls ${LOCAL_TARGET} |
			grep -oE "${EXPRESSION_GREP}" |
			sed 's/\(ocariot-monitor-\|-data\)//g')
	elif [ "$1" = "restore" ] && [ "${RESTORE_TARGET}" != "LOCAL" ]; then
		SERVICES=$(cloud_bkps "" ${VOLUME_COMMAND} |
			grep -oE "${EXPRESSION_GREP}" |
			sed 's/\(ocariot-monitor-\|-data\)//g')
	else
		SERVICES=$(docker volume ls --format "{{.Name}}" |
			grep -oE "${EXPRESSION_GREP}" |
			sed 's/\(ocariot-monitor-\|-data\)//g')
	fi
fi

SERVICES=$(echo ${SERVICES} | tr " " "\n" | sort -u)

for SERVICE in ${SERVICES}; do
	FULL_NAME_SERVICE=$(docker stack services ${MONITOR_STACK_NAME} \
		--format={{.Name}} 2>/dev/null |
		grep -w ${MONITOR_STACK_NAME}_.*${SERVICE})
	RUNNING_SERVICES="${RUNNING_SERVICES} ${FULL_NAME_SERVICE}"

	if [ "$1" = "restore" ] && [ "${RESTORE_TARGET}" = "LOCAL" ]; then
		MESSAGE="Not found ${SERVICE} volume!"
		VOLUME_NAME=$(ls ${LOCAL_TARGET} |
			grep -oE "${EXPRESSION_GREP}" |
			grep -w ${SERVICE})
	elif [ "$1" = "restore" ] && [ "${RESTORE_TARGET}" != "LOCAL" ]; then
		if [ -z "${CLOUD_BACKUPS}" ];then
			CLOUD_BACKUPS=$(cloud_bkps "" ${VOLUME_COMMAND})
		fi
		MESSAGE="Volume BKP ${SERVICE} not found!"
		VOLUME_NAME="$(echo ${CLOUD_BACKUPS} |
			grep -oE "${EXPRESSION_GREP}" |
			grep -w ${SERVICE})"
	else
		MESSAGE="Volume BKP ${SERVICE} not found!"
		VOLUME_NAME=$(docker volume ls \
			--format "{{.Name}}" |
			grep -oE "${EXPRESSION_GREP}" |
			grep -w ${SERVICE})
	fi

	if [ -z "${VOLUME_NAME}" ]; then
		echo "${MESSAGE}"
		exit
	fi
	VOLUMES_BKP="${VOLUMES_BKP} ${VOLUME_NAME}"
done

VOLUMES_BKP=$(echo "${VOLUMES_BKP}" | sed 's/ /\n/g' | sort -u)

if [ -z "${VOLUMES_BKP}" ]; then
	echo "Not found ${MONITOR_STACK_NAME} volumes!"
	exit
fi

remove_services "${RUNNING_SERVICES}"

if [ "$1" = "restore" ]; then
	remove_volumes "${VOLUMES_BKP}"
fi

INCREMENT=1
for VOLUME in ${VOLUMES_BKP}; do
	VOLUMES="${VOLUMES} -v ${VOLUME}:/source/${VOLUME}${SOURCE_VOLUME_PROPERTY}"
	INCREMENT=$((INCREMENT + 1))
done

PROCESS_BKP="OK"
BKP_CONFIG_MODEL=$(mktemp --suffix=.json)

docker run -d \
	--name ${BACKUP_CONTAINER_NAME} \
	${VOLUMES} \
	-v ${LOCAL_TARGET}:/local-backup${BACKUP_VOLUME_PROPERTY} \
	-v google_credentials:/credentials \
	-v ${BKP_CONFIG_MODEL}:/etc/volumerize/multiconfig.json:rw \
	blacklabelops/volumerize &> /dev/null

if [ -z "${BACKUP_DATA_RETENTION}" ]; then
	BACKUP_DATA_RETENTION="15D"
fi

INCREMENT=1
for VOLUME in ${VOLUMES_BKP}; do
	if [ "$1" = "backup" ]; then
		multi_backup_config "${BKP_CONFIG_MODEL}" "${VOLUME}"
	else
		restore_config "${BKP_CONFIG_MODEL}" "${VOLUME}"
	fi

	backup_container_operation restart

	echo "======Backup of ${VOLUME} volume======"

	docker exec -t \
		-e VOLUMERIZE_SOURCE=/source/${VOLUME} \
		-e VOLUMERIZE_TARGET="multi:///etc/volumerize/multiconfig.json?mode=mirror&onfail=abort" \
		-e GOOGLE_DRIVE_ID=${CLOUD_ACCESS_KEY_ID} \
		-e GOOGLE_DRIVE_SECRET=${CLOUD_SECRET_ACCESS_KEY} \
		-e AWS_ACCESS_KEY_ID=${CLOUD_ACCESS_KEY_ID} \
		-e AWS_SECRET_ACCESS_KEY=${CLOUD_SECRET_ACCESS_KEY} \
		${BACKUP_CONTAINER_NAME} bash -c "${COMMAND} && remove-older-than ${BACKUP_DATA_RETENTION} --force"

	if [ $? != 0 ]; then
		PROCESS_BKP=FALSE
		echo "Error during $1 operation"
		break
	fi
	INCREMENT=$((INCREMENT + 1))
done

remove_backup_container

if [ "${PROCESS_BKP}" = "OK" ]; then
	RUNNING_SERVICES=$(echo ${RUNNING_SERVICES} | sed 's/ //g')

	if [ "${RUNNING_SERVICES}" ]; then
		${INSTALL_PATH}/scripts/monitor/start.sh
	fi
fi
