#!/bin/bash

OPENVMI_DRIVER_DIR=/opt/openvmi/driver
BINDER_KO=$OPENVMI_DRIVER_DIR/binder_linux.ko
ASHMEM_KO=$OPENVMI_DRIVER_DIR/ashmem_linux.ko
DEV_INSTANCE_NUM=$1
FAILED=255

install_binder()
{
    if [ -e $BINDER_KO ]; then
        insmod $BINDER_KO num_devices=$(($DEV_INSTANCE_NUM+1))
        if [ $? != 0 ]; then
            echo "failed to insmod $BINDER_KO."
            exit $FAILED
        fi
    else 
        echo "$BINDER_KO isn't exist."
        exit $FAILED
    fi
}

lsmod | grep ashmem_linux > /dev/null
if [ $? -ne 0 ]; then
    if [ -e $ASHMEM_KO ]; then
        insmod $ASHMEM_KO 
        if [ $? != 0 ]; then
            echo "failed to insmod $ASHMEM_KO."
            exit $FAILED
        fi
    else 
        echo "$ASHMEM_KO isn't exist."
        exit $FAILED
    fi
fi

lsmod | grep binder_linux > /dev/null
if [ $? -ne 0 ]; then
    install_binder
else
    NUM=`ls /dev | grep binder | wc -l`
    if [ $NUM -ne $DEV_INSTANCE_NUM ]; then
        rmmod $BINDER_KO
        if [ $? != 0 ]; then
            echo "failed to rmmod $BINDER_KO."
            exit $FAILED
        fi
        install_binder
    fi
fi
