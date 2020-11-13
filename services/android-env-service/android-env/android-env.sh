#!/bin/bash

FAILED=255
OPENVMI_ROOT_DIR=/opt/openvmi
OPENVMI_BIN=$OPENVMI_ROOT_DIR/bin/openvmi
OPENVMI_LIB_DIR=$OPENVMI_ROOT_DIR/libs
OPENVMI_DRIVER_DIR=$OPENVMI_ROOT_DIR/driver
OPENVMI_ENV_DIR=$OPENVMI_ROOT_DIR/android-env
OPENVMI_CFG_DIR=$OPENVMI_ENV_DIR/docker/data
ANDROID_DATA_DIR=$OPENVMI_ROOT_DIR/android-data
ANDROID_SOCKET_DIR=$OPENVMI_ROOT_DIR/android-socket
SESSIONMANAGER="$OPENVMI_BIN session-manager"
INPUTS="event0 event1 event2"
OPENVMI_LOG_LEVEL="warning"
EGL_LOG_LEVEL="warning"
SESSIONMANAGERPID=""
FRAMEBUFFERPID=""

ANDROID_NAME=""
ANDROID_IDX=""
BINDER_IDX=""
X11VNC_PORT=""
X11VNC_PWD=""
ADB_PORT=""
SCREEN_WIDTH=""
SCREEN_HEIGHT=""
IP_ADDR=""
CIDR=""

function error()
{
	echo -e "\e[01;31m$ANDROID_IDX: $@ \e[0m" >&2
	exit $FAILED
}

function warning() 
{
	echo -e "\e[01;33m$ANDROID_IDX: $@ \e[0m"
}

function out() 
{
	echo -e "$ANDROID_IDX: $@"
}

function get_android_cfg_data()
{
	cfgFile=$OPENVMI_CFG_DIR/$1/init_cfg
	if [ ! -e $cfgFile ]; then
		error "$cfgFile isn't exist."
	fi

	tmp=`cat $cfgFile | grep androidIdx`
	ANDROID_IDX=${tmp#*:}

	tmp=`cat $cfgFile | grep ipAddr`
	IP_ADDR=${tmp#*:}
	if [[ $IP_ADDR == "" ]]; then
		IP_ADDR="192.168.1.1"
	fi

	tmp=`cat $cfgFile | grep netmask`
	tmp=${tmp#*:}
	if [[ $tmp == "255.255.0.0" ]]; then
		CIDR=16
	elif [[ $tmp == "255.0.0.0" ]]; then
		CIDR=8
	else
		CIDR=24
	fi

	tmp=`cat $cfgFile | grep binderIdx`
	BINDER_IDX=${tmp#*:}

	tmp=`cat $cfgFile | grep screenWidth`
	SCREEN_WIDTH=${tmp#*:}

	tmp=`cat $cfgFile | grep screenHeight`
	SCREEN_HEIGHT=${tmp#*:}

	tmp=`cat $cfgFile | grep vncPort`
	X11VNC_PORT=${tmp#*:}

	tmp=`cat $cfgFile | grep vncPwd`
	X11VNC_PWD=${tmp#*:}

	tmp=`cat $cfgFile | grep adbPort`
	ADB_PORT=${tmp#*:}
}

function start_binder_ashmem()
{
	BINDERNODE=/dev/binder$BINDER_IDX
	ASHMEMNODE=/dev/ashmem
	chmod 777 $BINDERNODE > /dev/null
	chmod 777 $ASHMEMNODE > /dev/null
}

function start_framebuffer()
{
	out "STARTING Frame Buffer"

	ps aux | grep -w Xvfb | grep -w "Xvfb[[:space:]]*:$ANDROID_IDX " > /dev/null
	if [[ $? -eq 0 ]]; then
		warning "Xvfb :$ANDROID_IDX is already running"
		return
	fi

	cmd="Xvfb :$ANDROID_IDX -ac -screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x24"
	$cmd > /dev/null &
	FRAMEBUFFERPID=$!
	disown

	if [[ ! -d /proc/$FRAMEBUFFERPID ]]; then
		error "FAILED to start the Frame Buffer"
	fi
}

function check_session_status()
{
	TIMEOUT=0
	while true; 
	do
		ps -h $SESSIONMANAGERPID > /dev/null
		if [[ $? -gt 0 ]]; then
			if [[ $TIMEOUT -gt 100 ]]; then
				error "FAILED to start the Session Manager"
			else
				TIMEOUT=$(($TIMEOUT+1))
			fi
			sleep 0.1
		else
			break
		fi
	done

	TIMEOUT=0
	while true;
	do
		if [[ -S $ANDROID_SOCKET_DIR/$ANDROID_NAME/sockets/qemu_pipe ]] &&
			[[ -S $ANDROID_SOCKET_DIR/$ANDROID_NAME/sockets/openvmi_bridge ]] &&
			[[ -S $ANDROID_SOCKET_DIR/$ANDROID_NAME/input/event0 ]] &&
			[[ -S $ANDROID_SOCKET_DIR/$ANDROID_NAME/input/event1 ]] &&
			[[ -S $ANDROID_SOCKET_DIR/$ANDROID_NAME/input/event2 ]]; then
			break
		else
			if [[ $TIMEOUT -gt 100 ]]; then
				error "FAILED: Timed out waiting for sockets"
			else
				sleep 0.1
				TIMEOUT=$(($TIMEOUT+1))
			fi
		fi
	done	

	chmod 777 $ANDROID_SOCKET_DIR/$ANDROID_NAME/sockets/* > /dev/null
	chmod 777 $ANDROID_SOCKET_DIR/$ANDROID_NAME/input/* > /dev/null
}

function start_session_manager()
{
	out "STARTING Session Manager"

	rm -rf $ANDROID_SOCKET_DIR/$ANDROID_NAME &> /dev/null

	ps aux | grep -v grep | grep -w "$SESSIONMANAGER" | grep -w "run-multiple=$ANDROID_NAME"  > /dev/null
	if [[ $? -eq 0 ]]; then
		warning "Session Manager $ANDROID_NAME:$BINDER_IDX is already running"
		return 
	fi
	
	export DISPLAY=:$ANDROID_IDX

	cmd="$SESSIONMANAGER --run-multiple=$ANDROID_NAME:$BINDER_IDX --adb-port=$ADB_PORT --experimental --software-rendering --single-window --window-size=${SCREEN_WIDTH},${SCREEN_HEIGHT} --no-touch-emulation"
	$cmd > /dev/null &
	SESSIONMANAGERPID=$!
	disown

	check_session_status 
	return $?
}

function start_vnc_server()
{
	out "STARTING VNC Server"

	ps aux | grep -v grep | grep -w "x11vnc" | grep -w "display :$ANDROID_IDX"  > /dev/null
	if [[ $? -eq 0 ]]; then
		warning "x11vnc display:$ANDROID_IDX is already running"
		return 
	fi
	
	rm -rf /tmp/.X11-unix/X$ANDROID_IDX &> /dev/null
	rm -rf /tmp/.X$ANDROID_IDX-lock &> /dev/null

	cmd="x11vnc -display :$ANDROID_IDX -rfbport $X11VNC_PORT -forever -shared -reopen -desktop $ANDROID_NAME -bg"
	$cmd -q &> /dev/null
	if [[ $? -ne 0 ]]; then
		error "FAILED to start the VNC Server"
	fi
}

function configure_network()
{
	if [[ $IP_ADDR != "" ]]; then
		out "CREATING network configuration (using $IP_ADDR)"

		ipCfgDir=$ANDROID_DATA_DIR/$ANDROID_NAME/data/misc/ethernet
		ipCfgFile=$ipCfgDir/ipconfig.txt
		if [ ! -e $ipCfgDir ]; then
			mkdir -p $ipCfgDir 
		fi

		$OPENVMI_BIN generate-ip-config --ip=$IP_ADDR --gateway="0.0.0.0" --cidr=$CIDR --ipcfg=$ipCfgFile
		if [[ $? -ne 0 ]]; then
			error "FAILED to configure Networking"
		fi
	fi
}

function start()
{
	export OPENVMI_LOG_LEVEL=$OPENVMI_LOG_LEVEL
	export EGL_LOG_LEVEL=$EGL_LOG_LEVEL
	export SWIFTSHADER_PATH=$OPENVMI_LIB_DIR/libswiftshader

	start_binder_ashmem
	if [[ $? -eq $FAILED ]]; then
		return $FAILED
	fi

	start_framebuffer
	if [[ $? -eq $FAILED ]]; then
		return $FAILED
	fi

	start_session_manager
	if [[ $? -eq $FAILED ]]; then
		return $FAILED
	fi

	start_vnc_server
	if [[ $? -eq $FAILED ]]; then
		return $FAILED
	fi

	configure_network
	if [[ $? -eq $FAILED ]]; then
		return $FAILED
	fi
}

function stop()
{
	# Stop VNC Server
	PID=$(ps aux | grep -w x11vnc | grep -w "display.*:$ANDROID_IDX " | column -t | cut -d$' ' -f3)
	if [[ "$PID" != "" ]]; then
		out "STOPPING VNC Server ($PID)"
		kill -INT $PID > /dev/null
	else
		warning "NOT stopping VNC Server, it's not running"
	fi

	# Stop Session Manager
	PID=$(ps aux | grep -v grep | grep -w "$SESSIONMANAGER" | grep -w "run-multiple=$ANDROID_NAME" | column -t | cut -d$' ' -f3)
	if [[ "$PID" != "" ]]; then
		out "STOPPING Session Manager ($PID)"
		if [[ "$PERF" == "true" ]]; then
			kill -INT $PID
		else
			kill -9 $PID
		fi
	else
		warning "NOT stopping Session Manager, it's not running"
	fi
	rm -rf $ANDROID_SOCKET_DIR/$ANDROID_NAME > /dev/null

	# Stop Frame Buffer
	PID=$(ps aux | grep -w Xvfb | grep -w "Xvfb[[:space:]]*:$ANDROID_IDX " | column -t | cut -d$' ' -f3)
	if [[ "$PID" != "" ]]; then
		out "STOPPING Frame Buffer ($PID)"
		kill -9 $PID > /dev/null
	else
		warning "NOT stopping Frame Buffer, it's not running"
	fi

	rm -f /tmp/.X11-unix/X$ANDROID_IDX
	rm -f /tmp/.X$ANDROID_IDX-lock

	# Remove unattached shared memory (VNC does not free it properly)
	IDS=`ipcs -m | grep '^0x' | grep $USER | awk '{print $2, $6}' | grep ' 0$' | awk '{print $1}'`
	for id in $IDS; do
		ipcrm shm $id &> /dev/null
	done
}

main()
{
	if [[ $# != 2 || $1 != "start" && $1 != "stop" ]]; then
		echo "$0 start|stop <android_name>"
		return $FAILED
	fi

	ANDROID_NAME=$2
	get_android_cfg_data $ANDROID_NAME

	if [[ $1 == "start" ]]; then
		out "Start android $ANDROID_NAME..."
		start
	elif  [[ $1 == "stop" ]]; then 
		out "Stop android $ANDROID_NAME..."
		stop
	fi

	return $?
}

main $@
exit $?
