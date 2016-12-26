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
	func clientBrowsingError(_ errorDict: [NSObject: AnyObject])

	/**
	 Called when a server is found by the browser.

	 - parameter server: An ALBPeer object initialized with a name, unique identifier, and other information used by the class.
	 */
	func serverFound(_ server: ALBPeer)

	/**
	 Called when a server is no longer seen by the browser.

	 - parameter server: An ALBPeer object initialized with a name and unique identifier.
	 */
	func serverLost(_ server: ALBPeer)

	/**
	 Called when the client is unable to connect to the server.

	 - parameter server: An ALBPeer object initialized with a name and unique identifier.
	 */
	func unableToConnect(_ server: ALBPeer)

	/**
	 Called when a server refused the connection.

	 - parameter server: An ALBPeer object initialized with a name and unique identifier.
	 */
	func connectionDenied(_ server: ALBPeer)

	/**
	 Called when the client has connected.

	 - parameter connection: A fully initialized ALBPeerConnection object.
	 */
	func connected(_ connection: ALBPeerConnection)
}

class ALBPeerClient: NSObject {
	var nearbyServers = [ALBPeer]()
	var delegate: ALBPeerClientDelegate?

	fileprivate var _serviceType: String
	fileprivate var _localNode: ALBPeer
	fileprivate var _server: ALBPeer?
	fileprivate var _socket: GCDAsyncSocket?
	fileprivate var _serviceBrowser: NetServiceBrowser?
	fileprivate var _foundPublishers = [NetService]()

	// MARK: - Initializer
	/**
	 Initializes the client class.

	 - parameter serviceType: The string signifying the type of service to be published on Bonjour, i.e. "_albservice._tcp."
	 - parameter serverNode: An ALBPeer object initialized with a name and unique identifier.
	 - parameter clientDelegate: A reference to an ALBPeerClientDelegate object. This parameter is optional.
	 **/
	init(serviceType: String, clientNode: ALBPeer, clientDelegate: ALBPeerClientDelegate?) {
		_serviceType = serviceType
		_localNode = clientNode
		delegate = clientDelegate
	}

	// MARK: - Browsing - Connecting
	/**
	 Start browsing for instances of a matching service.
	 **/
	func startBrowsing() {
		_serviceBrowser = NetServiceBrowser()
		_serviceBrowser?.delegate = self
		_serviceBrowser?.includesPeerToPeer = true
		_serviceBrowser?.searchForServices(ofType: _serviceType, inDomain: "")
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
	func connectToServer(_ server: ALBPeer) {
		if _socket != nil {
			_socket?.disconnect()
			_socket = nil
			_server = nil
		}

		var connecting = false

		let socket = GCDAsyncSocket(delegate: self, delegateQueue: ALBPeerConnectionQueue, socketQueue: ALBPeerConnectionQueue)
		if let hostName = server.service?.hostName, let port = server.service?.port {
			socket.delegate = self
			socket.isIPv4PreferredOverIPv6 = false
			do {
				try socket.connect(toHost: hostName, onPort: UInt16(port))
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
}

extension ALBPeerClient: NetServiceBrowserDelegate {
	// MARK: - Browser Delegate
	/**
	 Internal use only.
	 */
	func netServiceBrowserWillSearch(_ aNetServiceBrowser: NetServiceBrowser) {
		// not used
	}

	/**
	 Internal use only.
	 */
	func netServiceBrowser(_ aNetServiceBrowser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
		delegate?.clientBrowsingError(errorDict as [NSObject: AnyObject])
	}

	/**
	 Internal use only.
	 */
	func netServiceBrowser(_ aNetServiceBrowser: NetServiceBrowser, didFind aNetService: NetService, moreComing: Bool) {
		if aNetService.name != _localNode.name {
			aNetService.delegate = self

			// need a strong reference to stick around
			_foundPublishers.append(aNetService)
			aNetService.resolve(withTimeout: 10.0)
		}
	}

	/**
	 Internal use only.
	 */
	func netServiceBrowser(_ aNetServiceBrowser: NetServiceBrowser, didRemove aNetService: NetService, moreComing: Bool) {
		let matchingNodes = nearbyServers.filter({ $0.service == aNetService })
		if matchingNodes.count > 0 {
			nearbyServers = nearbyServers.filter({ $0.service != aNetService })
			delegate?.serverLost(matchingNodes[0])
		}
	}
}

extension ALBPeerClient: NetServiceDelegate {
	// MARK: - Service Delegate
	/**
	 Internal use only.
	 */
	func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
		// not used
		print(errorDict)
	}

	/**
	 Internal use only.
	 */
	func netServiceDidResolveAddress(_ service: NetService) {
		// watch for TXTRecord Updates
		service.startMonitoring()
	}

	/**
	 Internal use only.
	 */
	func netService(_ service: NetService, didUpdateTXTRecord data: Data) {
		let txtDict = NetService.dictionary(fromTXTRecord: data)
		if let idObject = txtDict["peerID"], let peerID = NSString(data: idObject, encoding: String.Encoding.utf8.rawValue) as? String, nearbyServers.filter({ $0.peerID == peerID }).count == 0 {
			let remoteNode = ALBPeer(name: service.name, peerID: peerID)
			remoteNode.service = service
			nearbyServers.append(remoteNode)
			delegate?.serverFound(remoteNode)
		}
	}

	/**
	 Internal use only.
	 */
	func netServiceDidStop(_ sender: NetService) {
		_foundPublishers = _foundPublishers.filter({ $0.name != sender.name })
	}
}

extension ALBPeerClient: GCDAsyncSocketDelegate {
	// MARK: - Socket Delegate
	/**
	 Internal use only.
	 */
	func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
		let data = ALBPeerPacket(type: ALBPeerPacketType.connectionRequest)
		_socket!.readData(to: ALBPeerPacketDelimiter as Data!, withTimeout: -1, tag: 0)
		sock.write(data.packetDataUsingData(_localNode.dataValue()), withTimeout: 0.5, tag: 0)
	}

	/**
	 Internal use only.
	 */
	func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
		if let server = _server {
			delegate?.unableToConnect(server)
			if let service = server.service, let browser = _serviceBrowser {
				netServiceBrowser(browser, didRemove: service, moreComing: false)
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
	func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
		if let packet = ALBPeerPacket(packetData: data), let remoteNode = ALBPeer(dataValue: packet.data!), packet.type == .connectionAccepted || packet.type == .connectionDenied {
			if packet.type == .connectionAccepted {
				let connection = ALBPeerConnection(socket: sock, remoteNode: remoteNode)
				delegate?.connected(connection)
			} else {
				delegate?.connectionDenied(remoteNode)
			}
		}
	}
}
