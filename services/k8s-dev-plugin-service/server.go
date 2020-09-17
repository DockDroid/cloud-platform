package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path"
	"strconv"
	"strings"
	"time"

	log "github.com/Sirupsen/logrus"
	"golang.org/x/net/context"
	"google.golang.org/grpc"
	pluginapi "k8s.io/kubernetes/pkg/kubelet/apis/deviceplugin/v1beta1"
)


type Device struct {
	devName string // example: /dev/fuse
	permissions string // must be "rwm" or it's subsets
}

// DevicePlugin represents 1 host device ( or 1 type host device)
type DevicePlugin struct {
	devName string // device node on host, for example: /dev/fuse
	permissions string // must be "rwm" or it's subsets
	baseName string // for example: fuse
	resourceName string // Resource name to register with kubelet, for example: openvmi/fuse
	unixSockPath string // DevicePluginPath ("/var/lib/kubelet/device-plugins/") + *.sock
	unixSock net.Listener
	gRpcServer *grpc.Server
	devInstances []*pluginapi.Device // Device instances
	isRigistered bool
	stopChan chan interface{}
}

type DevicePluginManager struct {
	devs []Device
	devPlugins []*DevicePlugin
}

const resourceNamePrefix = "openvmi/"
var devList = []Device {
	{ "/dev/fuse", "rwm" },
	{ "/dev/ashmem", "rwm" },
	{ "/dev/binder", "rwm" },
}


func initHostDevice( devInstanceNum int ) error {
	str := "/opt/openvmi/k8s-plugins/k8s-dev-init.sh " + strconv.Itoa( devInstanceNum )
	cmd := exec.Command( "/bin/bash", "-c", str )
	stderr, _ := cmd.StderrPipe()

	err := cmd.Start()
	if err != nil {
		return fmt.Errorf( "failed to start cmd: %s.", str )
	}

	errMsg := ""
	for {
		buf := make( []byte, 1024 )
		size, err := stderr.Read( buf )
		if err != nil {
			break
		}
		errMsg += string( buf[:size-1] )
	}

	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf( errMsg )
	}

	return nil
}

// newDevicePlugin returns an initialized DevicePlugin
func newDevicePlugin( dev *Device, devNum int ) (*DevicePlugin, error) {
	baseName := path.Base( dev.devName )

	devInstances := make( []*pluginapi.Device, devNum )
	for i := 0; i < devNum; i++ {
		devInstances[i] = &pluginapi.Device{ ID: baseName + strconv.Itoa(i+1), Health: pluginapi.Healthy }
	} 

	return &DevicePlugin{
		devName: 		dev.devName,
		permissions:    dev.permissions,
		baseName: baseName,
		resourceName:   resourceNamePrefix + baseName,
		unixSockPath:   pluginapi.DevicePluginPath + baseName + ".sock",
		devInstances:	devInstances,
		stopChan: 		make( chan interface{} ),
		isRigistered:   false,
	}, nil
}

func initPluginManager( devNum int ) (*DevicePluginManager, error) {
	mgr := DevicePluginManager {
		devs: devList,
		devPlugins: make( []*DevicePlugin, 0, 8 ),
	}

	for _, dev := range mgr.devs {
		plugin, err := newDevicePlugin( &dev, devNum )
		if err != nil {
			return nil, err
		}
		mgr.devPlugins = append( mgr.devPlugins, plugin )
		// fmt.Printf( "plugin info:\n%+v\n", plugin )
	}

	return &mgr, nil
}

func (mgr *DevicePluginManager) startGrpcServer() error {
	for _, plugin := range mgr.devPlugins {
		err := plugin.startGrpcServer()
		if err != nil {
			return err
		}
	}
	return nil
}

// start starts the gRPC server of the device plugin
func (plugin *DevicePlugin) startGrpcServer() error {
	os.Remove( plugin.unixSockPath )

	sock, err := net.Listen( "unix", plugin.unixSockPath )
	if err != nil {
		return err
	}

	plugin.unixSock = sock
	plugin.gRpcServer = grpc.NewServer( []grpc.ServerOption{}... )
	pluginapi.RegisterDevicePluginServer( plugin.gRpcServer, plugin )

	log.Printf( "Starting GRPC Server[socket:%s].", plugin.unixSockPath )
	go plugin.gRpcServer.Serve( plugin.unixSock )

	//Wait for server to start grpc server by launching a blocking connection
	conn, err := connectGrpcServer( plugin.unixSockPath, 5*time.Second )
	if err != nil {
		return err
	}
	conn.Close()

	return nil
}

func (mgr *DevicePluginManager) stopGrpcServer() {
	for _, plugin := range mgr.devPlugins {
		plugin.stopGrpcServer()
	}
}

// stop_grpc_server stops the gRPC server
func (plugin *DevicePlugin) stopGrpcServer() error {
	if plugin.gRpcServer == nil {
		return nil
	}

	plugin.gRpcServer.Stop()
	plugin.gRpcServer = nil
	plugin.isRigistered = false
	close( plugin.stopChan )
	os.Remove( plugin.unixSockPath )

	return nil
}

func (mgr *DevicePluginManager) registerToKubelet() error {
	for _, plugin := range mgr.devPlugins {
		if plugin.isRigistered {
			continue
		}
		err := plugin.registerToKubelet()
		if err != nil {
			return err
		}
	}

	return nil
}

// Register registers the device plugin for the given resourceName with Kubelet.
func (plugin *DevicePlugin) registerToKubelet() error {
	conn, err := connectGrpcServer( pluginapi.KubeletSocket, 5*time.Second )
	if err != nil {
		log.Errorf( "Fail to connect grpc server %s: %v\n", pluginapi.KubeletSocket, err )
		return err
	}
	defer conn.Close()

	client := pluginapi.NewRegistrationClient( conn )
	request := &pluginapi.RegisterRequest{
		Version:      pluginapi.Version,
		Endpoint:     path.Base( plugin.unixSockPath ),
		ResourceName: plugin.resourceName,
	}

	_, err = client.Register( context.Background(), request )
	if err != nil {
		plugin.isRigistered = false
		log.Errorf( "Register %s error: %v\n", plugin.devName, err )
		return err
	}
	plugin.isRigistered = true

	log.Printf( "Register %s success.", plugin.devName )

	return nil
}

// connectGrpcServer establishes the gRPC communication with the registered device plugin.
func connectGrpcServer( unixSocketPath string, timeout time.Duration ) (*grpc.ClientConn, error) {
	c, err := grpc.Dial( unixSocketPath, grpc.WithInsecure(), grpc.WithBlock(), grpc.WithTimeout(timeout), 
		grpc.WithDialer( func(addr string, timeout time.Duration) (net.Conn, error) {
			return net.DialTimeout( "unix", addr, timeout )
		}),
	)

	if err != nil {
		log.Errorf( "Connct grpc error: %v\n", err )
		return nil, err
	}

	return c, nil
}

// ListAndWatch lists devices and update that list according to the health status
func (plugin *DevicePlugin) ListAndWatch( e *pluginapi.Empty, s pluginapi.DevicePlugin_ListAndWatchServer ) error {
	s.Send( &pluginapi.ListAndWatchResponse{Devices: plugin.devInstances} )

	ticker := time.NewTicker( time.Second * 10 )

	for {
		select {
		case <-plugin.stopChan:
			return nil
		case <-ticker.C:
			s.Send( &pluginapi.ListAndWatchResponse{Devices: plugin.devInstances} )
		}
	}

	return nil
}

// Allocate which return list of devices.
func (plugin *DevicePlugin) Allocate( ctx context.Context, r *pluginapi.AllocateRequest ) (*pluginapi.AllocateResponse, error) {
	hostPath := plugin.devName

	devId := r.ContainerRequests[0].DevicesIDs[0]
	envs := make( map[string]string )
	if  strings.Contains(devId, "binder") {
		hostPath = "/dev/" + devId
		envs["ANDROID_BINDER_IDX"] = strings.Trim( devId, "binder" )
	}

	devSpec := pluginapi.DeviceSpec {
		HostPath: hostPath,
		ContainerPath: plugin.devName,
		Permissions: plugin.permissions,
	}

	var devicesList []*pluginapi.ContainerAllocateResponse
	devicesList = append( devicesList, &pluginapi.ContainerAllocateResponse { 
		Envs: envs,
		Annotations: make( map[string]string ),
		Devices: []*pluginapi.DeviceSpec{ &devSpec },
		Mounts: nil,})

		response := pluginapi.AllocateResponse{}
		response.ContainerResponses = devicesList

		//spew.Printf( "\n=====================[ %s ]==================\n", time.Now().Format("2006-01-02 15:04:05") )
		//spew.Printf( "AllocateRequest: %#v\n", *r )
		//spew.Printf( "AllocateResponse: %#v\n", devicesList )

		return &response, nil
	}

	func (plugin *DevicePlugin) GetDevicePluginOptions( context.Context, *pluginapi.Empty ) (*pluginapi.DevicePluginOptions, error) {
		return &pluginapi.DevicePluginOptions{ PreStartRequired: false }, nil
	}

	func (plugin *DevicePlugin) PreStartContainer( context.Context, *pluginapi.PreStartContainerRequest ) (*pluginapi.PreStartContainerResponse, error) {
		return &pluginapi.PreStartContainerResponse{}, nil
	}

