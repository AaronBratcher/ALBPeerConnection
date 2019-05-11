# ALBPeerConnection
[![CocoaPods](https://img.shields.io/cocoapods/v/ALBPeerConnection.svg)](https://cocoapods.org/)

Peer-Peer networking classes written (mostly) in Swift. (Socket is Objective-C class GCDAsyncSocket)

See the Shopping project for an example of using this class to sync between instances of an app.

**This class uses Swift 5**

** To Do:
* Add Unit Testing
* Add secure connections


Peer to Peer classes for communicating between nearby devices over wifi or bluetooth.

## What's new in version 3.0.2 ##
* Developed and tested with Xcode 10.2 using Swift 5


## Getting Started ##
A client and server are initialized with a name and unique identifier for each. The server publishes itself on Bonjour so the client can see it.

When the client requests a connection with the server, a delegate call is made passing the name and unique identifier of the client so a determination can be made if a connection should be allowed through code or user interaction.

Once a connection is made, all communication is made through the ALBPeerCommunication class.

### Server ###

Initialize an instance of the server.
```swift
let netNode = ALBPeer(name: "Server device", peerID: "uniquedeviceid")
let netServer = ALBPeerServer(serviceType:"_albsync._tcp.", serverNode:netNode, serverDelegate:nil)
netServer.delegate = self
```

Start the server, allowing it to be seen and connected to.
```swift
if !netServer.startPublishing() {
	// handle error
}
```

Stop the server, removing it from view on the network and disallowing new connections.
```swift
	netServer.stopPublishing()
```

Required delegate calls.
```swift
func serverPublishingError(errorDict: [NSObject : AnyObject]) {
	println("publishing error: \(errorDict)")
}

func allowConnectionRequest(remoteNode:ALBPeer, requestResponse:(allow:Bool)->()) {
	// do work to determine if this device should be allowed to connect
	// this can involve user interface calls etc.
	// requestResponse can be saved and called elsewhere
	requestResponse(allow: true)
}

func clientDidConnect(connection:ALBPeerConnection) {
	// connection delegate must be assigned immediately
	connection.delegate = self

	// strong reference must be kept of the connection
	_netConnections.append(connection)
}
```

### Client ###

initialize an instance of the client.
```swift
let netNode = ALBPeer(name: "Client device", peerID: "uniquedeviceid")
let netClient = ALBPeerClient(serviceType:"_albsync._tcp.", clientNode:netNode, clientDelegate:nil)
netClient.delegate = self
```

Browse for servers. Any servers found or lost will invoke delegate calls.
```swift
netClient.startBrowsing()
```

Stop browsing.
```swift
netClient.stopBrowsing()
```

Request a connection to a server.
```swift
netClient.connectToServer(peerDevice)
```

Required delegate calls.
```swift
func clientBrowsingError(errorDict:[NSObject: AnyObject]) {
	println("browsing error: \(errorDict)")
}

func serverFound(server:ALBPeer) {
	// a server has been found
}

func serverLost(server:ALBPeer) {
	// a server is no longer seen
}

func unableToConnect(server:ALBPeer) {
	// was unable to connect
}

func connectionDenied(server:ALBPeer) {
	// connection was denied
}

func connected(connection:ALBPeerConnection) {
	// connection delegate must be assigned immediately
	connection.delegate = self

	// strong reference must be kept of the connection
	_netConnection = connection
}
```

### Connection ###

Close the connection.
```swift
connection.disconnect()
```

Send text, data, and local resources to the remote connection

```swift
connection.sendText("sample text string")
connection.sendData(dataObject)
let progressTracker = connection.sendResourceAtURL(localURL, name:"fileName", resourceID:"unique identifier", onCompletion: { (sent) -> () in
	// do some cleanup, etc.
})
```

Required delegate calls.
```swift
func disconnected(connection:ALBPeerConnection, byRequest:Bool) {
	// connection closed
}

func textReceived(connection: ALBPeerConnection, text: String) {
	// text received
}

func dataReceived(connection:ALBPeerConnection, data:Data) {
	// data received
}

func startedReceivingResource(connection:ALBPeerConnection, atURL:URL, name:String, resourceID:String, progress:Progress) {
	// resource transfer started
}

func resourceReceived(connection:ALBPeerConnection, atURL:URL, name:String, resourceID:String) {
	// resource transfer complete
}
```
