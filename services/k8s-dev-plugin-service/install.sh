#!/bin/bash

K8S_PLUGINS_DIR=/opt/openvmi/k8s-plugins
SYSTEMD_SERVICE_DIR=/lib/systemd/system
PLUGIN_SYSTEMD_FILE=k8s-dev-plugin.service
PLUGIN_SERVICE_BIN=k8s-dev-plugin
PLUGIN_DEV_INIT_SH=k8s-dev-init.sh
FAILED=255

check()
{
	if [ $1 != 0 ]; then
		exit $FAILED
	fi
}

install_golang()
{
	goPkg=go1.14.2.linux-arm64

	wget https://dl.google.com/go/$goPkg.tar.gz > /dev/null
	check $?

	gunzip $goPkg.tar.gz > /dev/null
	check $?

	rm /opt/go -rf > /dev/null
	tar -xf $goPkg.tar -C /opt/ > /dev/null
	check $?

	rm $goPkg.tar > /dev/null
}

if [ ! -d $K8S_PLUGINS_DIR ]; then
	mkdir -p $K8S_PLUGINS_DIR
	check $?
fi

which make > /dev/null
if [ $? != 0 ]; then
	apt install make
	check $?
fi 

export PATH=$PATH:/opt/go/bin
which go > /dev/null
if [ $? != 0 ]; then
	install_golang
fi

make clean
make bin
check $?

systemctl stop $PLUGIN_SYSTEMD_FILE &> /dev/null

cp $PLUGIN_DEV_INIT_SH $K8S_PLUGINS_DIR/$PLUGIN_DEV_INIT_SH
check $?
chmod +x $K8S_PLUGINS_DIR/$PLUGIN_DEV_INIT_SH
check $?

cp $PLUGIN_SERVICE_BIN $K8S_PLUGINS_DIR/$PLUGIN_SERVICE_BIN
check $?
chmod +x $K8S_PLUGINS_DIR/$PLUGIN_SERVICE_BIN
check $?

systemctl stop $PLUGIN_SYSTEMD_FILE &> /dev/null

cp $PLUGIN_SYSTEMD_FILE $SYSTEMD_SERVICE_DIR
check $?
systemctl enable $PLUGIN_SYSTEMD_FILE
check $?
systemctl start $PLUGIN_SYSTEMD_FILE
check $?

echo ""

sleep 1
systemctl status $PLUGIN_SYSTEMD_FILE
