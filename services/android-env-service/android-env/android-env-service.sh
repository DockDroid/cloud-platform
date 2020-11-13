#!/bin/bash

FAILED=255
SERVICE_RUN_PID_FILE=/run/android_env_service.pid
OPENVMI_ROOT_DIR=/opt/openvmi
ANDROID_DATA_DIR=$OPENVMI_ROOT_DIR/android-data
ANDROID_ENV_DIR=$OPENVMI_ROOT_DIR/android-env
ANDROID_ENV_MANAGE_SH=$ANDROID_ENV_DIR/android-env.sh
INIT_DATA_ROOT_DIR=$ANDROID_ENV_DIR/docker/data
INIT_QUEUE_FILE=$ANDROID_ENV_DIR/docker/init.queue
UNINIT_QUEUE_FILE=$ANDROID_ENV_DIR/docker/uninit.queue
DELETE_QUEUE_FILE=$ANDROID_ENV_DIR/docker/delete.queue
ANDROID_NAME=""

init_android_run_env()
{
	echo "++++++++++++++++++++++++++++++++++++++++++++++++++"
	initStatusFile=$INIT_DATA_ROOT_DIR/$1/init_status

	$ANDROID_ENV_MANAGE_SH "start" "$1"
	ret=$?

	echo -n $ret > $initStatusFile

	if [ $ret != 0 ];then
		echo -e "\e[01;31m>>>>>>>>>>$1 init failed.\e[0m"
		uninit_android_run_env "$1"
	else
		echo -e "\e[01;32m>>>>>>>>>>$1 init ok.\e[0m"
	fi
}

uninit_android_run_env()
{
    echo "-------------------------------------------------"
    $ANDROID_ENV_MANAGE_SH "stop" "$1"
}

delete_android_vm()
{	
	rm -rf $INIT_DATA_ROOT_DIR/$1 &> /dev/null
	
	count=10
	while [ $count -gt 1 ]
	do
		rm $ANDROID_DATA_DIR/$1 -rf &> /dev/null
		if [ $? = 0 ]; then
			break
		fi
		sleep 1
		let count--
	done

	echo "delete android($1) data ok."
}

trap "rm $SERVICE_RUN_PID_FILE &> /dev/null; exit" INT HUP TERM QUIT

if [ -e $SERVICE_RUN_PID_FILE ]; then
    echo "error: app is running."
    exit $FAILED
else
    touch $SERVICE_RUN_PID_FILE
    if [ $? != 0 ]; then
        exit $FAILED
    fi
    echo $$ > $SERVICE_RUN_PID_FILE
fi

sysctl -w fs.inotify.max_user_instances=81920 > /dev/null
if [ $? != 0 ]; then
	exit $FAILED
fi
sysctl -w kernel.shmmni=24576 > /dev/null
if [ $? != 0 ]; then
	exit $FAILED
fi
sysctl -w fs.file-max=1000000 > /dev/null
if [ $? != 0 ]; then
	exit $FAILED
fi
sysctl -w kernel.pid_max=4119481 > /dev/null
if [ $? != 0 ]; then
	exit $FAILED
fi

echo -e "\n=============== start service to manager android running env ===============[pid:$$]\n"
while true
do
	while [ -s $INIT_QUEUE_FILE ]; do
		ANDROID_NAME=`head -1 $INIT_QUEUE_FILE`
		if [ "$ANDROID_NAME" != "" ]; then
			init_android_run_env $ANDROID_NAME 
		fi
		sed -i '1d' $INIT_QUEUE_FILE;
	done

	if [ -s $UNINIT_QUEUE_FILE ]; then
		while [ -s $UNINIT_QUEUE_FILE ]; do
			ANDROID_NAME=`head -1 $UNINIT_QUEUE_FILE`
			if [ "$ANDROID_NAME" != "" ]; then
				uninit_android_run_env $ANDROID_NAME
			fi
			sed -i '1d' $UNINIT_QUEUE_FILE;
		done
	else
		while [ -s $DELETE_QUEUE_FILE ]; do
			ANDROID_NAME=`head -1 $DELETE_QUEUE_FILE`
			if [ "$ANDROID_NAME" != "" ]; then
				delete_android_vm $ANDROID_NAME
			fi
			sed -i '1d' $DELETE_QUEUE_FILE
		done
	fi

	sleep 0.1
done




