//
//  ALBPeerConnection.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 3/13/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

protocol ALBPeerClientDelegate {
	/**
	Called when the client could not start the browser.
	
	- parameter errorDict: A dictionary containing details of the error.
	*/
	func clientBrowsingError(errorDict:[NSObject: AnyObject])
	
	/**
	Called when a server is found by the browser.
	
	- parameter server: An ALBPeer object initialized with a name, unique identifier, and other information used by the class.
	*/
	func serverFound(server:ALBPeer)
	
	/**
	Called when a server is no longer seen by the browser.
	
	- parameter server: An ALBPeer object initialized with a name and unique identifier.
	*/
	func serverLost(server:ALBPeer)
	
	/**
	Called when the client is unable to connect to the server.
	
	- parameter server: An ALBPeer object initialized with a name and unique identifier.
	*/
	func unableToConnect(server:ALBPeer)
	
	/**
	Called when a server refused the connection.
	
	- parameter server: An ALBPeer object initialized with a name and unique identifier.
	*/
	func connectionDenied(server:ALBPeer)
	
	/**
	Called when the client has connected.
	
	- parameter connection: A fully initialized ALBPeerConnection object.
	*/
	func connected(connection:ALBPeerConnection)
}

class ALBPeerClient:NSObject,NSNetServiceBrowserDelegate,NSNetServiceDelegate,GCDAsyncSocketDelegate {
	var nearbyServers = [ALBPeer]()
	var delegate:ALBPeerClientDelegate?
	
	private var _serviceType:String
	private var _localNode:ALBPeer
	private var _server:ALBPeer?
	private var _socket:GCDAsyncSocket?
	private var _serviceBrowser:NSNetServiceBrowser?
	private var _foundPublishers = [NSNetService]()
	
	//MARK: - Initializer
	/**
	Initializes the client class.
	
	- parameter serviceType: The string signifying the type of service to be published on Bonjour, i.e. "_albservice._tcp."
	- parameter serverNode: An ALBPeer object initialized with a name and unique identifier.
	- parameter clientDelegate: A reference to an ALBPeerClientDelegate object. This parameter is optional.
	**/
	init(serviceType:String, clientNode:ALBPeer, clientDelegate:ALBPeerClientDelegate?) {
		_serviceType = serviceType
		_localNode = clientNode
		delegate = clientDelegate
	}
	
	//MARK: - Browsing - Connecting
	/**
	Start browsing for instances of a matching service.
	**/
	func startBrowsing() {
		_serviceBrowser = NSNetServiceBrowser()
		_serviceBrowser?.delegate = self
		_serviceBrowser?.includesPeerToPeer = true
		_serviceBrowser?.searchForServicesOfType(_serviceType, inDomain: "")
	}
	
	/**
	Stop browsing
	**/
	func stopBrowsing() {
		_serviceBrowser?.stop()
		_serviceBrowser = nil
	}
	
	/**
	Request a connection to the given server.
	
	- parameter server: An ALBPeer object returned by the serverFound delegate call.
	*/
	func connectToServer(server:ALBPeer) {
		if _socket != nil {
			_socket?.disconnect()
			_socket = nil
			_server = nil
		}
		
		var connecting = false
		
		if let socket = GCDAsyncSocket(delegate: self, delegateQueue: ALBPeerConnectionQueue, socketQueue: ALBPeerConnectionQueue), hostName = server.service?.hostName, port = server.service?.port {
			socket.delegate = self
			socket.IPv4PreferredOverIPv6 = false
			do {
				try socket.connectToHost(hostName, onPort: UInt16(port))
				connecting = true
				_socket = socket
				_server = server
			} catch _ {
				// not connecting
			}
			
		}
		
		if !connecting {
			delegate?.unableToConnect(server)
		}
	}
	
	//MARK: - Browser Delegate
	/**
	Internal use only.
	*/
	func netServiceBrowserWillSearch(aNetServiceBrowser: NSNetServiceBrowser) {
		// not used
	}
	
	/**
	Internal use only.
	*/
	func netServiceBrowser(aNetServiceBrowser: NSNetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
		delegate?.clientBrowsingError(errorDict)
	}
	
	/**
	Internal use only.
	*/
	func netServiceBrowser(aNetServiceBrowser: NSNetServiceBrowser, didFindService aNetService: NSNetService, moreComing: Bool) {
		if aNetService.name != _localNode.name {
			aNetService.delegate = self
			
			// need a strong reference to stick around
			_foundPublishers.append(aNetService)
			aNetService.resolveWithTimeout(10.0)
		}
	}
	
	/**
	Internal use only.
	*/
	func netServiceBrowser(aNetServiceBrowser: NSNetServiceBrowser, didRemoveService aNetService: NSNetService, moreComing: Bool) {
		let matchingNodes = nearbyServers.filter({$0.service == aNetService})
		if matchingNodes.count > 0 {
			nearbyServers = nearbyServers.filter({$0.service != aNetService})
			delegate?.serverLost(matchingNodes[0])
		}
	}
	
	//MARK: - Service Delegate
	/**
	Internal use only.
	*/
	func netService(sender: NSNetService, didNotResolve errorDict: [String : NSNumber]) {
		// not used
		print(errorDict)
	}
	
	/**
	Internal use only.
	*/
	func netServiceDidResolveAddress(service:NSNetService) {
		// watch for TXTRecord Updates
		service.startMonitoring()
	}
	
	/**
	Internal use only.
	*/
	func netService(service: NSNetService, didUpdateTXTRecordData data: NSData) {
		let txtDict = NSNetService.dictionaryFromTXTRecordData(data)
		if let idObject = txtDict["peerID"], peerID =  NSString(data: idObject, encoding: NSUTF8StringEncoding) as? String where nearbyServers.filter({$0.peerID == peerID}).count == 0 {
			let remoteNode = ALBPeer(name: service.name, peerID: peerID)
			remoteNode.service = service
			nearbyServers.append(remoteNode)
			delegate?.serverFound(remoteNode)
		}
	}
	
	/**
	Internal use only.
	*/
	func netServiceDidStop(sender: NSNetService) {
		_foundPublishers = _foundPublishers.filter({$0.name != sender.name})
	}
	
	//MARK: - Socket Delegate
	/**
	Internal use only.
	*/
	func socket(sock: GCDAsyncSocket!, didConnectToHost host: String!, port: UInt16) {
		let data = ALBPeerPacket(type: ALBPeerPacketType.connectionRequest)
		_socket!.readDataToData(ALBPeerPacketDelimiter, withTimeout: -1, tag: 0)
		sock.writeData(data.packetDataUsingData(_localNode.dataValue()), withTimeout: 0.5, tag: 0)
	}
	
	/**
	Internal use only.
	*/
	func socketDidDisconnect(sock: GCDAsyncSocket!, withError err: NSError!) {
		if let server = _server {
			delegate?.unableToConnect(server)
			if let service = server.service, browser = _serviceBrowser {
				netServiceBrowser(browser, didRemoveService: service, moreComing: false)
			}
		}
		_server = nil
		_socket = nil
		
		stopBrowsing()
		startBrowsing()
	}
	
	/**
	Internal use only.
	*/
	func socket(sock: GCDAsyncSocket!, didReadData data: NSData!, withTag tag: Int) {
		if let packet = ALBPeerPacket(packetData: data), remoteNode = ALBPeer(dataValue: packet.data!) where packet.type == .connectionAccepted || packet.type == .connectionDenied {
			if packet.type == .connectionAccepted {
				let connection = ALBPeerConnection(socket: sock, remoteNode: remoteNode)
				delegate?.connected(connection)
			} else {
				delegate?.connectionDenied(remoteNode)
			}
		}
	}
}
