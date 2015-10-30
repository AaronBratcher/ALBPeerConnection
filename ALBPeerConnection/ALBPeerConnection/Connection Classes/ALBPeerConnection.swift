//
//  ALBPeerConnection.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 3/13/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation


protocol ALBPeerConnectionDelegate {
	/**
	Called when the connection to the remote has been broken.
	
	- parameter connection: The connection that has been disconnected.
	- parameter byRequest: Is true if the disconnect was by request.
	*/
	
	func disconnected(connection:ALBPeerConnection, byRequest:Bool)
	
	/**
	Called when text has been received from the remote.
	
	- parameter connection: The connection that received the text.
	- parameter text: The text that was received.
	*/
	func textReceived(connection:ALBPeerConnection, text:String)
	
	/**
	Called when data has been received from the remote.
	
	- parameter connection: The connection that received the data.
	- parameter data: The data that was received.
	*/
	func dataReceived(connection:ALBPeerConnection, data:NSData)
	
	/**
	Called when this connection has started to receive a resource from the remote.
	
	- parameter connection: The connection that is receiving the resource.
	- parameter atURL: The location of the resource.
	- parameter name: The given name of the resource.
	- parameter resourceID: The unique identifier of the resource
	- parameter progress: An NSProgress object that is updated as the file is received. This cannot be canceled at this time.
	*/
	func startedReceivingResource(connection:ALBPeerConnection, atURL:NSURL, name:String, resourceID:String, progress:NSProgress)
	
	/**
	Called when this connection has finished receiving a resource from the remote.
	
	- parameter connection: The connection that is receiving the resource.
	- parameter atURL: The location of the resource.
	- parameter name: The given name of the resource.
	- parameter resourceID: The unique identifier of the resource
	*/
	func resourceReceived(connection:ALBPeerConnection, atURL:NSURL, name:String, resourceID:String)
}




let ALBPeerConnectionQueue = dispatch_queue_create("com.AaronLBratcher.ALBPeerConnectionQueue", nil)
let ALBPeerPacketDelimiter = NSData(bytes:[0x0B,0x1B,0x1B] as [UInt8], length: 3)   // VerticalTab Esc Esc
let ALBPeerMaxDataSize = 65536
let ALBPeerWriteTimeout = NSTimeInterval(60)

class ALBPeerConnection:NSObject,GCDAsyncSocketDelegate {
	var delegate:ALBPeerConnectionDelegate? {
		didSet {
			_socket.readDataToData(ALBPeerPacketDelimiter, withTimeout: -1, tag: 0)
		}
	}
	
	var delegateQueue = dispatch_get_main_queue()
	
	var remotNode:ALBPeer
	private var _socket:GCDAsyncSocket
	private var _disconnecting = false
	private var _pendingPackets = [Int:ALBPeerPacket]()
	private var _lastTag = 0
	private var _cachedData:NSMutableData?
	private var _resourceFiles = [String:Resource]()
	
	class Resource {
		var handle:NSFileHandle
		var path:String
		var name:String
		var progress = NSProgress()
		
		init(handle:NSFileHandle, path:String, name:String) {
			self.handle = handle
			self.path = path
			self.name = name
			self.progress.cancellable = false
		}
	}
	
	//MARK: - Initializers
	/* this is called by the client or server class. Do not call this directly. */
	init(socket:GCDAsyncSocket, remoteNode:ALBPeer) {
		_socket = socket
		self.remotNode = remoteNode
		super.init()
		socket.delegate = self
	}
	
	//MARK: - Public Methods
	/* Disconnect from the remote. If there are pending packets to be sent, they will be sent before disconnecting. */
	func disconnect() {
		_disconnecting = true
		if _pendingPackets.count == 0 {
			_socket.disconnect()
		}
	}
	
	/**
	Send a text string to the remote.
	
	- parameter text: The text to send.
	*/
	func sendText(text:String) {
		let packet = ALBPeerPacket(type:.text)
		let data = text.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
		_pendingPackets[_lastTag] = packet
		_socket.writeData(packet.packetDataUsingData(data), withTimeout: ALBPeerWriteTimeout, tag: _lastTag)
		_lastTag++
	}
	
	/**
	Send data to the remote.
	
	- parameter data: The data to send.
	*/
	func sendData(data:NSData) {
		let packet = ALBPeerPacket(type:.data)
		_pendingPackets[_lastTag] = packet
		_socket.writeData(packet.packetDataUsingData(data), withTimeout: ALBPeerWriteTimeout, tag: _lastTag)
		_lastTag++
	}
	
	/**
	Send a file to the remote.
	
	- parameter url: The URL path to the file.
	- parameter name: The name of the file.
	- parameter resourceID: A unique string identifier to this resource.
	- parameter onCompletion: A block of code that will be called when the resource has been sent
	
	- returns: NSProgress This will be updated as the file is sent. Currently, a send cannot be canceled.
	*/
	func sendResourceAtURL(url:NSURL, name:String, resourceID:String, onCompletion:completionHandler) -> NSProgress {
		let data = try! NSData(contentsOfURL: url, options: NSDataReadingOptions.MappedRead)
		var resource = ALBPeerResource(identity: resourceID, name: name, url: url, data: data)
		resource.onCompletion = onCompletion
		resource.progress = NSProgress(totalUnitCount: Int64(resource.length))
		resource.progress?.cancellable = false
		
		sendResourcePacket(resource)
		return resource.progress!
	}
	
	private func sendResourcePacket(var resource:ALBPeerResource) {
		var packet = ALBPeerPacket(type: .resource)
		
		let dataSize = max(ALBPeerMaxDataSize,resource.length - resource.offset)
		resource.offset += dataSize
		if resource.offset >= resource.length {
			packet.isFinal = true
		}
		
		if let progress = resource.progress {
			progress.completedUnitCount = Int64(resource.offset)
		}
		
		packet.resource = resource
		
		let range = NSMakeRange(0, dataSize)
		let subData = resource.mappedData!.subdataWithRange(range)
		_pendingPackets[_lastTag] = packet
		_socket.writeData(packet.packetDataUsingData(subData), withTimeout: ALBPeerWriteTimeout, tag: _lastTag)
		_lastTag++
	}
	
	// MARK: - Socket Delegate
	/**
	This is for internal use only
	**/
	func socket(sock: GCDAsyncSocket!, didWriteDataWithTag tag: Int) {
		if let packet = _pendingPackets[tag] {
			_pendingPackets.removeValueForKey(tag)
			
			if _disconnecting && _pendingPackets.count == 0 && (packet.type == .data || packet.isFinal) {
				_socket.disconnectAfterWriting()
				return
			}
			
			// if this is a resource packet... send next packet
			if packet.type == .resource {
				if !packet.isFinal {
					sendResourcePacket(packet.resource!)
				} else {
					if let resource = packet.resource, completionHandler = resource.onCompletion {
						completionHandler(sent: true)
					}
				}
			}
		}
	}
	
	/**
	This is for internal use only
	**/
	func socket(sock: GCDAsyncSocket!, didReadData data: NSData!, withTag tag: Int) {
		if let packet = ALBPeerPacket(packetData: data) {
			processPacket(packet)
		} else {
			// store data from this read and append to it with data from next read
			if _cachedData == nil {
				_cachedData = NSMutableData()
			}
			
			_cachedData!.appendBytes(data.bytes, length:data.length)
			if _cachedData!.length > ALBPeerMaxDataSize * 4 {
				_socket.disconnect()
				return
			}
			
			if let packet = ALBPeerPacket(packetData: _cachedData!) {
				processPacket(packet)
			}
		}
		
		_socket.readDataToData(ALBPeerPacketDelimiter, withTimeout: -1, tag: 0)
	}
	
	private func processPacket(packet:ALBPeerPacket) {
		_cachedData = nil
		
		switch packet.type {
		case .text:
			dispatch_async(delegateQueue, {[unowned self] () -> Void in
				if let delegate = self.delegate {
					delegate.textReceived(self, text: NSString(data: packet.data!, encoding: NSUTF8StringEncoding) as! String)
				} else {
					print("Connection delegate is not assigned")
				}
			})
		case .data:
			dispatch_async(delegateQueue, {[unowned self] () -> Void in
				if let delegate = self.delegate {
					delegate.dataReceived(self, data: packet.data!)
				} else {
					print("Connection delegate is not assigned")
				}
			})
		case .resource:
			if let resourceID = packet.resource?.identity, name = packet.resource?.name, resourceLength = packet.resource?.length, packetLength = packet.data?.length {
				let handle:NSFileHandle
				var resourcePath:String
				var resource = _resourceFiles[packet.resource!.identity]

				if let resource = resource {
					handle = resource.handle
					resourcePath = resource.path
				} else {
					// create file
					let searchPaths = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)
					let documentFolderPath = searchPaths[0] 
					resourcePath = "\(documentFolderPath)/\(name)"
					var nameIndex = 1
					while NSFileManager.defaultManager().fileExistsAtPath(resourcePath) {
						let parts = resourcePath.componentsSeparatedByString(".")
						resourcePath = ""
						if parts.count > 1 {
							let partCount = parts.count-1
							for partIndex in 0..<partCount {
								resourcePath = "\(resourcePath).\(parts[partIndex])"
							}
							resourcePath = "\(resourcePath)-\(nameIndex)"
							resourcePath = "\(resourcePath).\(parts[parts.count-1])"
						} else {
							resourcePath = "\(resourcePath)\(nameIndex)"
						}
						
						nameIndex = nameIndex + 1
					}
					
					NSFileManager.defaultManager().createFileAtPath(resourcePath, contents: nil, attributes: nil)
					if let fileHandle = NSFileHandle(forWritingAtPath:resourcePath) {
						resource = Resource(handle:fileHandle, path: resourcePath, name:name)
						var progress = NSProgress(totalUnitCount: Int64(resourceLength))
						resource?.progress = progress
						_resourceFiles[resourceID] = resource
						handle = fileHandle
					} else {
						resourceCopyError(resourceID, name: name)
						return
					}
					
					dispatch_async(delegateQueue, {[unowned self] () -> Void in
						if let delegate = self.delegate {
							delegate.startedReceivingResource(self, atURL: NSURL(fileURLWithPath: resourcePath), name: packet.resource!.name, resourceID: resourceID, progress:resource!.progress)
						} else {
							print("Connection delegate is not assigned")
						}
					})
				}
				
				if let progress = resource?.progress {
					progress.completedUnitCount = progress.completedUnitCount + packetLength
				}
				
				handle.writeData(packet.data!)
				
				if packet.isFinal {
					handle.closeFile()
					let resource = _resourceFiles[resourceID]!
					_resourceFiles.removeValueForKey(resourceID)
					dispatch_async(delegateQueue, {[unowned self] () -> Void in
						if let delegate = self.delegate {
							delegate.resourceReceived(self, atURL: NSURL(fileURLWithPath: resourcePath), name: resource.name, resourceID: resourceID)
						} else {
							print("Connection delegate is not assigned")
						}
					})
				}
			} else {
				resourceCopyError("**Unknown**", name: "**Unknown**")
				return
			}
		case .resourceError:
			if let resource = packet.resource, completionHandler = resource.onCompletion {
				completionHandler(sent: false)
			}
		default:
			// other cases handled elsewhere
			break
		}
	}
	
	private func resourceCopyError(resourceID:String, name:String) {
		let resource = ALBPeerResource(identity: resourceID, name: name)
		var packet = ALBPeerPacket(type: .resourceError)
		packet.resource = resource
		
		_socket.writeData(packet.packetDataUsingData(nil), withTimeout: ALBPeerWriteTimeout, tag: 0)
	}
	
	/**
	This is for internal use only
	**/
	func socketDidDisconnect(sock: GCDAsyncSocket!, withError err: NSError!) {
		dispatch_async(delegateQueue, {[unowned self] () -> Void in
			if let delegate = self.delegate {
				delegate.disconnected(self, byRequest: self._disconnecting)
			} else {
				print("Connection delegate is not assigned")
			}
		})
	}
}