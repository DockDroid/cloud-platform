package main

import (
	"flag"
	log "github.com/Sirupsen/logrus"
	"github.com/fsnotify/fsnotify"
	pluginapi "k8s.io/kubernetes/pkg/kubelet/apis/deviceplugin/v1beta1"
	"os"
	"runtime"
	"strconv"
	"syscall"
	"time"
)

const pidFile = "/run/k8s_dev_plugin_service.pid"

var devInstanceNum = runtime.NumCPU()

func createPidFile() error {
	file, err := os.Create( pidFile )
	if err != nil {
		return err
	}
	defer file.Close()

	_, err = file.WriteString( strconv.Itoa(os.Getpid()) )
	if err != nil {
		return err
	}

	return nil
}

func deletePidFile() {
	_ = os.Remove( pidFile )
}

func appIsRunning() bool {
	_, err := os.Stat( pidFile )
	if err != nil {
		if os.IsNotExist( err ) {
			return false
		}
	}

	return true
}

func main() {
	var err error
	var pluginManager *DevicePluginManager

	if appIsRunning() {
		log.Fatal( "app is running." )
	}

	flag.Parse()

	err = initHostDevice( devInstanceNum )
	if err != nil {
		log.Fatal( "Failed to init host device. error: ", err )
	}

	log.Println( "Starting FS watcher." )
	watcher, err := newFsWatcher( pluginapi.DevicePluginPath )
	if err != nil {
		log.Fatal( "Failed to created FS watcher. error: ", err )
	}
	defer watcher.Close()

	log.Println( "Starting OS watcher." )
	sigCh := newOsWatcher( syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT )

	err = createPidFile()
	if err != nil {
		log.Fatal( "Failed to created app pid file. error: ", err )
	}
	defer deletePidFile()

	restart := true
	for {
		if restart {
			log.Println( "Starting init plugin manager." )
			pluginManager, err = initPluginManager( devInstanceNum )
			if err != nil {
				log.Fatal( "Failed to init plugin manager. error: ", err )
			}

			log.Println( "Starting grpc server." )
			err = pluginManager.startGrpcServer()
			if err != nil {
				log.Fatal( "Failed to start grpc server. error: ", err )
			}

			log.Println( "Starting register to kubelet." )
			err = pluginManager.registerToKubelet()
			if err != nil {
				log.Errorf( "Failed to register to kubelet. error: ", err )
				pluginManager.stopGrpcServer()
				time.Sleep( 5*time.Second )
				continue
			}

			restart = false
		}

		select {
		case err := <-watcher.Errors:
			log.Printf( "Inotify: %s", err )

		case event := <-watcher.Events:
			if event.Name == pluginapi.KubeletSocket && event.Op&fsnotify.Create == fsnotify.Create {
				log.Printf( "Inotify: %s created, restarting.", pluginapi.KubeletSocket )
				pluginManager.stopGrpcServer()
				restart = true	
			}

		case sig := <-sigCh:
			switch sig {
			case syscall.SIGHUP:
				log.Println( "Received SIGHUP, restarting." )
				pluginManager.stopGrpcServer()
				restart = true		

			default:
				log.Printf( "Received signal \"%v\", shutting down.", sig )
				pluginManager.stopGrpcServer()
				return
			}
		}
	}
}

