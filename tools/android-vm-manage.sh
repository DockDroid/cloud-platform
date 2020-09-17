#!/bin/bash

##################################### 虚拟机自定义配置 ###################################
#虚拟机镜像，默认为android:latest
ANDROID_IMAGE="android:openvmi"
#vCPU核数
ANDROID_CPUS=4
#内存大小，单位MB
ANDROID_MEMORY=4096
#屏幕分辨率宽度
ANDROID_SCREEN_WIDTH=720
#屏幕分辨率高度
ANDROID_SCREEN_HEIGHT=1280
#宿主机上的虚拟机VNC起始端口号（虚拟机vnc端口 = 虚拟机VNC起始端口号 + 虚拟机编号）
ANDROID_VNC_BASE_PORT=5399
#宿主机上的虚拟机ADB起始端口号（虚拟机adb端口 = 虚拟机ADB起始端口号 + 虚拟机编号）
ANDROID_ADB_BASE_PORT=5199
#########################################################################################
#########################################################################################
#########################################################################################
#########################################################################################
#########################################################################################
#########################################################################################
#########################################################################################
OP_STATUS_FILE=/tmp/.openvmi_android_op_status
ANDROID_TEMPLATE_YAML=
ANDROID_OP=
ANDROID_TOTAL_NUM=
ANDROID_BASE_NAME=
ANDROID_START_IDX=
ANDROID_END_IDX=
ANDROID_NAME=
ANDROID_IDX=
ANDROID_VNC_PORT=
ANDROID_ADB_PORT=


print_help()
{
cat <<EOF

本脚本提供对虚拟机的创建、删除、开机、关机和重启操作，使用说明如下：

./android-vm-manage  create|delete|startup|shutdown|reboot  <k8s_node>|-  <start_android_idx>  [<end_android_idx>]

参数说明：
<k8s_node>：
	创建虚拟机的服务器主机名，“-”表示在当前服务器创建虚拟机。
<start_android_idx>：
	创建单台虚拟机时指定的编号或创建多台虚拟机时指定的起始编号。
<end_android_idx>：
	创建多台虚拟机时指定的结束编号。

EOF
}

vm_is_exist()
{
	kubectl get statefulset -n openvmi $1 &> /dev/null
	if [ $? != 0 ]; then
		echo "error: $vm isn't exist."
		ANDROID_TOTAL_NUM=$(($ANDROID_TOTAL_NUM-1))	
		return -1
	fi

	return 0
}

create_namespace()
{
	kubectl get namespace | grep -w openvmi &> /dev/null
	if [ $? != 0 ]; then
		kubectl create namespace openvmi
	fi
}

generate_ss_yaml()
{
ANDROID_TEMPLATE_YAML=$(cat <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $ANDROID_NAME
  namespace: openvmi
spec:
  replicas: 1
  serviceName: android-svc-$ANDROID_NAME
  selector:
    matchLabels:
      androidName: $ANDROID_NAME
  template:
    metadata:
      labels:
        androidName: $ANDROID_NAME
      name: $ANDROID_NAME
      namespace: openvmi
      annotations:
        container.apparmor.security.beta.kubernetes.io/android: unconfined
        container.seccomp.security.alpha.kubernetes.io/android: localhost/android.json
    spec:
      nodeName: $ANDROID_BASE_NAME
      tolerations:
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      terminationGracePeriodSeconds: 3
      initContainers:
      - name: init-android
        image: busybox
        imagePullPolicy: IfNotPresent
        command: [ "/openvmi/android-cfg-init.sh" ]
        resources:
          limits:
            openvmi/binder: 1
        volumeMounts:
        - mountPath: /openvmi
          name: volume-openvmi
        env:
        - name: ANDROID_NAME
          value: $ANDROID_NAME
        - name: ANDROID_IDX
          value: "$ANDROID_IDX"
        - name: ANDROID_VNC_PORT
          value: "$ANDROID_VNC_PORT"
        - name: ANDROID_ADB_PORT
          value: "$ANDROID_ADB_PORT"
        - name: ANDROID_SCREEN_WIDTH
          value: "$ANDROID_SCREEN_WIDTH"
        - name: ANDROID_SCREEN_HEIGHT
          value: "$ANDROID_SCREEN_HEIGHT" 
      containers:
      - image: $ANDROID_IMAGE
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 1
            memory: 1024Mi
          limits:
            cpu: $ANDROID_CPUS
            memory: ${ANDROID_MEMORY}Mi
            openvmi/fuse: 1
            openvmi/ashmem: 1
            openvmi/binder: 1
        command: [ "/openvmi-init.sh"]
        name: android
        securityContext:
          capabilities:
            add: [ "SYS_ADMIN", "NET_ADMIN", "SYS_MODULE", "SYS_NICE", "SYS_TIME", "SYS_TTY_CONFIG", "NET_BROADCAST", "IPC_LOCK", "SYS_RESOURCE" ]
        env:
        - name: ANDROID_NAME
          value: $ANDROID_NAME
        - name: PATH
          value: /system/bin:/system/xbin
        - name: ANDROID_DATA
          value: /data
        lifecycle:
          preStop:
            exec:
              command: [ "/openvmi/android-env-uninit.sh" ]
        readinessProbe:
          initialDelaySeconds: 5
          periodSeconds: 2
          timeoutSeconds: 1
          successThreshold: 1
          failureThreshold: 30
          exec:
            command: [ "sh", "-c", "getprop sys.boot_completed | grep 1" ]
        volumeMounts:
        - mountPath: /openvmi
          name: volume-openvmi
        - mountPath: /dev/qemu_pipe
          name: volume-pipe
        - mountPath: /dev/openvmi_bridge:rw
          name: volume-bridge
        - mountPath: /dev/input/event0:rw
          name: volume-event0
        - mountPath: /dev/input/event1:rw
          name: volume-event1
        - mountPath: /dev/input/event2:rw
          name: volume-event2
        - mountPath: /data:rw
          name: volume-data
      volumes:
      - name: volume-openvmi
        hostPath:
          path: /opt/openvmi/android-env/docker
      - name: volume-pipe
        hostPath:
          path: /opt/openvmi/android-socket/$ANDROID_NAME/sockets/qemu_pipe
      - name: volume-bridge
        hostPath:
          path: /opt/openvmi/android-socket/$ANDROID_NAME/sockets/openvmi_bridge
      - name: volume-event0
        hostPath:
          path: /opt/openvmi/android-socket/$ANDROID_NAME/input/event0
      - name: volume-event1
        hostPath:
          path: /opt/openvmi/android-socket/$ANDROID_NAME/input/event1
      - name: volume-event2
        hostPath:
          path: /opt/openvmi/android-socket/$ANDROID_NAME/input/event2
      - name: volume-data
        hostPath:
          path: /opt/openvmi/android-data/$ANDROID_NAME/data
EOF
)
}

create_android_vm()
{
	echo "create $1..."

	ANDROID_NAME=$1
	ANDROID_IDX=$((10#$2))
	ANDROID_VNC_PORT=$(($ANDROID_VNC_BASE_PORT+$ANDROID_IDX))
	ANDROID_ADB_PORT=$(($ANDROID_ADB_BASE_PORT+$ANDROID_IDX))
	
	generate_ss_yaml
	
	echo "$ANDROID_TEMPLATE_YAML" | kubectl apply -f - > /dev/null
	if [ $? != 0 ]; then
		return
	fi

	while true
	do
		kubectl get pod -n openvmi 2> /dev/null | grep $ANDROID_NAME | grep Running > /dev/null
		if [ $? = 0 ]; then
			break
		fi
		sleep 1
	done

	echo 1 >> $OP_STATUS_FILE
	echo "$1 created ok."
}

delete_android_data()
{
jobYaml=$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  namespace: openvmi
spec:
  template:
    metadata:
      name: $1
      namespace: openvmi
    spec:
      nodeName: $ANDROID_BASE_NAME
      tolerations:
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      restartPolicy: OnFailure
      containers:
      - image: busybox
        imagePullPolicy: IfNotPresent
        name: busybox
        command: [ "sh", "-c", "echo $1 >> /android-env/delete.queue" ]
        volumeMounts:
        - mountPath: /android-env
          name: android-env
      volumes:
      - name: android-env
        hostPath:
          path: /opt/openvmi/android-env/docker
EOF
)

	echo "$jobYaml" | kubectl apply -f - > /dev/null
        if [ $? != 0 ]; then
               return -1
        fi
	
	while true
	do
		kubectl get job -n openvmi | grep $1 | grep 1/1 > /dev/null
		if [ $? = 0 ]; then
			break
		fi
		sleep 1 
	done

	kubectl delete job -n openvmi $1 > /dev/null

	return 0
}

delete_android_vm()
{
	echo "delete $1..."

	vmName=$1
	kubectl delete statefulset -n openvmi $vmName > /dev/null
	if [ $? != 0 ]; then
		return
	fi

	while true
	do
		kubectl get pod -n openvmi 2> /dev/null | grep $vmName > /dev/null
		if [ $? != 0 ]; then
			break
		fi
		sleep 1
	done

	delete_android_data $vmName
	if [ $? != 0 ]; then
		return
	fi
	
	echo 1 >> $OP_STATUS_FILE
	echo "$1 deleted ok."
}

startup_android_vm()
{
	echo "startup $1..."

	vmName=$1
	kubectl patch statefulset -n openvmi $vmName -p "{\"spec\":{\"replicas\":1}}" > /dev/null
	if [ $? != 0 ]; then
		return
	fi

	while true
	do
		kubectl get pod -n openvmi 2> /dev/null | grep $vmName | grep Running > /dev/null
		if [ $? = 0 ]; then
			break
		fi
		sleep 1
	done

	echo 1 >> $OP_STATUS_FILE
	echo "$1 startup ok."
}

shutdown_android_vm()
{
	echo "shutdown $1..."

	vmName=$1
	kubectl patch statefulset -n openvmi $vmName -p "{\"spec\":{\"replicas\":0}}" > /dev/null
	if [ $? != 0 ]; then
		return
	fi

	while true
	do
		kubectl get pod -n openvmi 2> /dev/null | grep $vmName > /dev/null
		if [ $? != 0 ]; then
			break
		fi
		sleep 1
	done

	echo 1 >> $OP_STATUS_FILE
	echo "$1 shutdown ok."
}

reboot_android_vm()
{
	echo "start reboot $1..."

	vmName=$1
	kubectl patch statefulset -n openvmi $vmName -p "{\"spec\":{\"replicas\":0}}" > /dev/null
	if [ $? != 0 ]; then
		return
	fi

	while true
	do
		kubectl get pod -n openvmi 2> /dev/null | grep $vmName > /dev/null
		if [ $? != 0 ]; then
			break
		fi
		sleep 1
	done

	kubectl patch statefulset -n openvmi $vmName -p "{\"spec\":{\"replicas\":1}}" > /dev/null
	if [ $? != 0 ]; then
		return
	fi

	while true
	do
		kubectl get pod -n openvmi 2> /dev/null | grep $vmName | grep Running > /dev/null
		if [ $? = 0 ]; then
			break
		fi
		sleep 1
	done

	echo 1 >> $OP_STATUS_FILE
	echo "$1 reboot ok."
}

wait_op_finish()
{
	okNum=0
	while true
	do
		count=`cat $OP_STATUS_FILE | wc -l`
		if [ $count -ne $okNum ]; then
			echo -e "\e[01;36m$count VMs $ANDROID_OP OK.\e[0m"
			okNum=$count		
		fi	

		if [ $okNum -eq $ANDROID_TOTAL_NUM ]; then
			break;
		fi
	done
}

check_param()
{
	if [[ $1 != "create" && $1 != "delete" && $1 != "startup" && $1 != "shutdown" && $1 != "reboot" || $# < 3 || $# > 4 ]]; then
		print_help
		exit -1
	fi
	
	ANDROID_BASE_NAME=$2
	if [[ $ANDROID_BASE_NAME = "-" ]]; then
		ANDROID_BASE_NAME=$(hostname)
	fi

	kubectl get node | grep $ANDROID_BASE_NAME > /dev/null
	if [[ $? != 0 ]]; then
		echo "error: unknown k8s node."
		exit -1
	fi	

	ANDROID_START_IDX=$3
	if [ $# = 3 ]; then
		ANDROID_END_IDX=$ANDROID_START_IDX
	else
		ANDROID_END_IDX=$4
	fi

	if [ $ANDROID_START_IDX -lt 1 ]; then
		echo "error: invalid <start_android_idx>."
		exit -1
	fi

	if [ $ANDROID_END_IDX -lt $ANDROID_START_IDX ]; then
		echo "error: invalid <end_android_idx>."
		exit -1
	fi
	
	ANDROID_TOTAL_NUM=$(($ANDROID_END_IDX-$ANDROID_START_IDX+1))
}

check_param $@
create_namespace
echo -n "" > $OP_STATUS_FILE &> /dev/null
ANDROID_OP=`echo $1 | tr 'a-z' 'A-Z'`
echo -e "\e[01;36mSTART $ANDROID_OP $ANDROID_TOTAL_NUM VMs...\e[0m"
START_TIME=`date +%s`
for (( i=$ANDROID_START_IDX; i<=$ANDROID_END_IDX; i++ ))
do
	d=`printf "%02d" $i`
	vm=$ANDROID_BASE_NAME-$d
	if [[ $1 != create ]]; then
		vm_is_exist $vm
		if [ $? != 0 ]; then
			continue
		fi
	fi
	$1_android_vm $vm $d &
done
wait_op_finish
END_TIME=`date +%s`
echo -e "\e[01;35mTOTAL TIME:\e[0m $(($(($END_TIME-$START_TIME))/60))m$(($(($END_TIME-$START_TIME))%60))s\n"



