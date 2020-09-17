#!/bin/bash

FAILED=255
ANDROID_ENV_DIR=/opt/openvmi/android-env
ANDROID_DATA_DIR=/opt/openvmi/android-data
SYSTEMD_SERVICE_DIR=/lib/systemd/system
SERVICE_SYSTEMD_FILE=android-env.service
ANDROID_SECCOMP_FILE=android.json
K8S_SECCOMP_DIR=/var/lib/kubelet/seccomp

check()
{
	if [ $1 != 0 ]; then
		exit $FAILED
	fi
}

if [ ! -d $ANDROID_ENV_DIR ]; then
	mkdir -p $ANDROID_ENV_DIR
	check $?
fi

if [ ! -d $ANDROID_DATA_DIR ]; then
	mkdir -p $ANDROID_DATA_DIR
	check $?
fi

if [ ! -d $K8S_SECCOMP_DIR ]; then
	mkdir -p $K8S_SECCOMP_DIR
	check $?
fi

which Xvfb > /dev/null
if [ $? != 0 ]; then
	apt install xvfb
	check $?
fi 

which x11vnc > /dev/null
if [ $? != 0 ]; then
	apt install x11vnc
	check $?
fi 

cp $ANDROID_SECCOMP_FILE $K8S_SECCOMP_DIR
check $?

cp android-env/* $ANDROID_ENV_DIR -rf
check $?

cp $SERVICE_SYSTEMD_FILE $SYSTEMD_SERVICE_DIR
check $?
systemctl enable $SERVICE_SYSTEMD_FILE
check $?
systemctl stop $SERVICE_SYSTEMD_FILE &> /dev/null
check $?
systemctl start $SERVICE_SYSTEMD_FILE
check $?

echo ""

sleep 1
systemctl status $SERVICE_SYSTEMD_FILE
