#!/system/bin/sh

WORKDIR=/openvmi
UNINIT_QUEUE_FILE=$WORKDIR/uninit.queue

echo $ANDROID_NAME >> $UNINIT_QUEUE_FILE
