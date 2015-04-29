//
//  ALBPeerConnection.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 3/13/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

typealias ALBConnectionRequestResponse = (allow:Bool)->()
protocol ALBPeerServerDelegate {
	/**
	Called when the server could not publish.
	
	:param: errorDict Dictionary with details of the error.
	*/
	func serverPublishingError(errorDict: [NSObject : AnyObject])
	
	/**
	Called when a connection is requested.
	
	:param: remoteNode An ALBPeer object initialized with a name and a unique identifier.
	:param: requestResponse A closure that is to be called with a Bool indicating whether to allow the connection or not. This can be done asynchronously so a dialog can be invoked, etc.
	*/
    func allowConnectionRequest(remoteNode:ALBPeer, requestResponse:ALBConnectionRequestResponse)

	/**
	Called when a client has connected.
	
	:param: connection A fully initialized ALBPeerConnection object.
	*/
	func clientDidConnect(connection:ALBPeerConnection)
}

class ALBPeerServer:NSObject,NSNetServiceDelegate,GCDAsyncSocketDelegate {
    var delegate:ALBPeerServerDelegate?
    
    private var _serviceType:String
    private var _localNode:ALBPeer
    private var _netService:NSNetService?
    private var _socket:GCDAsyncSocket?
    private var _connectingSockets = [GCDAsyncSocket]()

    let _initialHandshakeTimeout = 2.0
    
    //MARK: - Initializer
	/**
	Initializes the server class.

	:param: serviceType The string signifying the type of service to be published on Bonjour, i.e. "_albservice._tcp."
	:param: serverNode An ALBPeer object initialized with a name and unique identifier.
	:param: serverDelegate A reference to an ALBPeerServerDelegate object. This parameter is optional.
	**/
	init(serviceType:String, serverNode:ALBPeer, serverDelegate:ALBPeerServerDelegate) {
		_serviceType = serviceType
		_localNode = serverNode
		delegate = serverDelegate
	}
	
	
    //MARK: - publishing
	/**
	Starts publishing as a service that can be found by clients and connected to.
	
	:returns: Bool Whether publishing was successful or not.
	*/
    func startPublishing() -> Bool {
        var publishing = false
        
        if let serverSocket = GCDAsyncSocket(delegate: self, delegateQueue: ALBPeerConnectionQueue, socketQueue: ALBPeerConnectionQueue) where serverSocket.acceptOnPort(0, error: nil) {
            serverSocket.IPv4PreferredOverIPv6 = false
            _socket = serverSocket
            
            let port = Int32(serverSocket.localPort)
            
            if let service = NSNetService(domain: "", type: _serviceType, name: _localNode.name, port: port) {
                _netService = service
                service.delegate = self
                service.includesPeerToPeer = true
                service.publish()
                
                publishing = true
            }
        }
        
        return publishing
    }
    
	/**
	Stops publishing the service and disallows any additional connections.
	*/
    func stopPublishing() {
        _netService?.stop()
        _netService = nil
    }
    
    // MARK: - Service Delegate
	/**
	Internal use only.
	*/
    func netServiceWillPublish(service: NSNetService) {
    }
    
	/**
	Internal use only.
	*/
    func netService(sender: NSNetService, didNotPublish errorDict: [NSObject : AnyObject]) {
        delegate?.serverPublishingError(errorDict)
    }
    
	/**
	Internal use only.
	*/
    func netServiceDidPublish(service: NSNetService) {
        let txtDict = ["peerID":_localNode.peerID]
        let txtData = NSNetService.dataFromTXTRecordDictionary(txtDict)
        if !service.setTXTRecordData(txtData) {
            println("did not set txtRecord")
        }
    }
    
    //MARK: - socket Delegate
	/**
	Internal use only.
	*/
    func socketDidDisconnect(sock: GCDAsyncSocket!, withError err: NSError!) {
        
    }
    
	/**
	Internal use only.
	*/
    func socket(sock: GCDAsyncSocket!, didAcceptNewSocket newSocket: GCDAsyncSocket!) {
        _connectingSockets.append(newSocket)
        newSocket.readDataToData(ALBPeerPacketDelimiter, withTimeout: _initialHandshakeTimeout, tag: 0)
    }
    
	/**
	Internal use only.
	*/
    func socket(sock: GCDAsyncSocket!, didReadData data: NSData!, withTag tag: Int) {
        // client should send clientIdentity information packet
        if let packet = ALBPeerPacket(packetData: data), clientNode = ALBPeer(dataValue: packet.data!) where packet.type == .connectionRequest {
            _connectingSockets = _connectingSockets.filter({$0 != sock})

            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                delegate?.allowConnectionRequest(clientNode, requestResponse: { (allow) -> () in
                    if allow {
                        // write back connection allowed data packet
                        let accepted = ALBPeerPacket(type: .connectionAccepted)
                        sock.writeData(accepted.packetDataUsingData(self._localNode.dataValue()), withTimeout: self._initialHandshakeTimeout, tag: 1)
                        let connection = ALBPeerConnection(socket: sock, remoteNode: clientNode)
                        self.delegate?.clientDidConnect(connection)
                    } else {
                        let denied = ALBPeerPacket(type: .connectionDenied)
                        sock.writeData(denied.packetDataUsingData(self._localNode.dataValue()), withTimeout: self._initialHandshakeTimeout, tag: 2)
                        sock.disconnectAfterWriting()
                    }
                })
            })
        }
    }
}
