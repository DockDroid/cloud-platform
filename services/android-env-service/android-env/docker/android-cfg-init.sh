#!/bin/sh

FAILED=255
WORKDIR=/openvmi
INIT_QUEUE_FILE=$WORKDIR/init.queue
DATA_DIR=$WORKDIR/data/$ANDROID_NAME
INIT_CFG_FILE=$DATA_DIR/init_cfg
INIT_STATUS_FILE=$DATA_DIR/init_status

init_failed()
{
    if [ $1 != 0 ]; then
        sh_exec_error
        exit $FAILED
    fi
}

if [ ! -d $DATA_DIR ];then
	mkdir -p $DATA_DIR
	if [ $? != 0 ]; then
	    init_failed
	fi
fi

touch $INIT_CFG_FILE
echo -n "" > $INIT_CFG_FILE
echo "androidName:$ANDROID_NAME" >> $INIT_CFG_FILE
echo "androidIdx:$ANDROID_IDX" >> $INIT_CFG_FILE
echo "vncPort:$ANDROID_VNC_PORT" >> $INIT_CFG_FILE
echo "adbPort:$ANDROID_ADB_PORT" >> $INIT_CFG_FILE
echo "binderIdx:$ANDROID_BINDER_IDX" >> $INIT_CFG_FILE
echo "screenWidth:$ANDROID_SCREEN_WIDTH" >> $INIT_CFG_FILE
echo "screenHeight:$ANDROID_SCREEN_HEIGHT" >> $INIT_CFG_FILE
echo "ipAddr:`ifconfig eth0 | grep "inet addr" | cut -f 2 -d ":" | cut -f 1 -d " "`" >> $INIT_CFG_FILE
echo "netmask:`ifconfig |grep inet| sed -n '1p'|awk '{print $4}'|awk -F ':' '{print $2}'`" >> $INIT_CFG_FILE

echo -n "" > $INIT_STATUS_FILE
echo $ANDROID_NAME >> $INIT_QUEUE_FILE

while true
do 	
	if [ ! -s $INIT_STATUS_FILE ]; then
		continue
	else
		status=`cat $INIT_STATUS_FILE`
		if [ $status = 0 ];then
			exit 0
		else
			init_failed
		fi
	fi
done
