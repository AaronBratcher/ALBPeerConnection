//
//  ALBPeerConnection.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 3/13/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

public protocol ALBPeerConnectionDelegate {
	/**
	 Called when the connection to the remote has been broken.

	 - parameter connection: The connection that has been disconnected.
	 - parameter byRequest: Is true if the disconnect was by request.
	 */
	
	func disconnected(_ connection: ALBPeerConnection, byRequest: Bool)
	
	/**
	 Called when text has been received from the remote.

	 - parameter connection: The connection that received the text.
	 - parameter text: The text that was received.
	 */
	func textReceived(_ connection: ALBPeerConnection, text: String)
	
	/**
	 Called when data has been received from the remote.

	 - parameter connection: The connection that received the data.
	 - parameter data: The data that was received.
	 */
	func dataReceived(_ connection: ALBPeerConnection, data: Data)
	
	/**
	 Called when this connection has started to receive a resource from the remote.

	 - parameter connection: The connection that is receiving the resource.
	 - parameter atURL: The location of the resource.
	 - parameter name: The given name of the resource.
	 - parameter resourceID: The unique identifier of the resource
	 - parameter progress: An NSProgress object that is updated as the file is received. This cannot be canceled at this time.
	 */
	func startedReceivingResource(_ connection: ALBPeerConnection, atURL: URL, name: String, resourceID: String, progress: Progress)
	
	/**
	 Called when this connection has finished receiving a resource from the remote.

	 - parameter connection: The connection that is receiving the resource.
	 - parameter atURL: The location of the resource.
	 - parameter name: The given name of the resource.
	 - parameter resourceID: The unique identifier of the resource
	 */
	func resourceReceived(_ connection: ALBPeerConnection, atURL: URL, name: String, resourceID: String)
}




let ALBPeerConnectionQueue = DispatchQueue(label: "com.AaronLBratcher.ALBPeerConnectionQueue")
let ALBPeerPacketDelimiter = Data(bytes: UnsafePointer<UInt8>([0x0B, 0x1B, 0x1B] as [UInt8]), count: 3) // VerticalTab Esc Esc
let ALBPeerMaxDataSize = 65536
let ALBPeerWriteTimeout = TimeInterval(60)

public final class ALBPeerConnection: NSObject, GCDAsyncSocketDelegate {
	public var delegate: ALBPeerConnectionDelegate? {
		didSet {
			_socket.readData(to: ALBPeerPacketDelimiter, withTimeout: -1, tag: 0)
		}
	}
	
	public var delegateQueue = DispatchQueue.main
	public var remotNode: ALBPeer
	
	fileprivate var _socket: GCDAsyncSocket
	fileprivate var _disconnecting = false
	fileprivate var _pendingPackets = [Int: ALBPeerPacket]()
	fileprivate var _lastTag = 0
	fileprivate var _cachedData: Data?
	fileprivate var _resourceFiles = [String: Resource]()
	
	class Resource {
		var handle: FileHandle
		var path: String
		var name: String
		var progress = Progress()
		
		init(handle: FileHandle, path: String, name: String) {
			self.handle = handle
			self.path = path
			self.name = name
			self.progress.isCancellable = false
		}
	}
	
	// MARK: - Initializers
	/* this is called by the client or server class. Do not call this directly. */
	public init(socket: GCDAsyncSocket, remoteNode: ALBPeer) {
		_socket = socket
		self.remotNode = remoteNode
		super.init()
		socket.delegate = self
	}
	
	// MARK: - Public Methods
	/* Disconnect from the remote. If there are pending packets to be sent, they will be sent before disconnecting. */
	public func disconnect() {
		_disconnecting = true
		if _pendingPackets.count == 0 {
			_socket.disconnect()
		}
	}
	
	/**
	 Send a text string to the remote.

	 - parameter text: The text to send.
	 */
	public func sendText(_ text: String) {
		let packet = ALBPeerPacket(type: .text)
		let data = text.data(using: String.Encoding.utf8, allowLossyConversion: false)
		_pendingPackets[_lastTag] = packet
		_socket.write(packet.packetDataUsingData(data), withTimeout: ALBPeerWriteTimeout, tag: _lastTag)
		_lastTag += 1
	}
	
	/**
	 Send data to the remote.

	 - parameter data: The data to send.
	 */
	public func sendData(_ data: Data) {
		let packet = ALBPeerPacket(type: .data)
		_pendingPackets[_lastTag] = packet
		_socket.write(packet.packetDataUsingData(data), withTimeout: ALBPeerWriteTimeout, tag: _lastTag)
		_lastTag += 1
	}
	
	/**
	 Send a file to the remote.

	 - parameter url: The URL path to the file.
	 - parameter name: The name of the file.
	 - parameter resourceID: A unique string identifier to this resource.
	 - parameter onCompletion: A block of code that will be called when the resource has been sent

	 - returns: NSProgress This will be updated as the file is sent. Currently, a send cannot be canceled.
	 */
	public func sendResourceAtURL(_ url: URL, name: String, resourceID: String, onCompletion: @escaping completionHandler) -> Progress {
		let data = try! Data(contentsOf: url, options: NSData.ReadingOptions.mappedRead)
		var resource = ALBPeerResource(identity: resourceID, name: name, url: url, data: data)
		resource.onCompletion = onCompletion
		resource.progress = Progress(totalUnitCount: Int64(resource.length))
		resource.progress?.isCancellable = false
		
		sendResourcePacket(resource)
		return resource.progress!
	}
	
	private func sendResourcePacket(_ resource: ALBPeerResource) {
		var resource = resource
		var packet = ALBPeerPacket(type: .resource)
		
		let dataSize = max(ALBPeerMaxDataSize, resource.length - resource.offset)
		resource.offset += dataSize
		if resource.offset >= resource.length {
			packet.isFinal = true
		}
		
		if let progress = resource.progress {
			progress.completedUnitCount = Int64(resource.offset)
		}
		
		packet.resource = resource
		
		let range = Range(0..<resource.offset + dataSize)
		let subData = resource.mappedData!.subdata(in: range)
		_pendingPackets[_lastTag] = packet
		_socket.write(packet.packetDataUsingData(subData), withTimeout: ALBPeerWriteTimeout, tag: _lastTag)
		_lastTag += 1
	}
	
	// MARK: - Socket Delegate
	/**
	 This is for internal use only
	 **/
	public func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
		if let packet = _pendingPackets[tag] {
			_pendingPackets.removeValue(forKey: tag)
			
			if _disconnecting && _pendingPackets.count == 0 && (packet.type == .data || packet.isFinal) {
				_socket.disconnectAfterWriting()
				return
			}
			
			// if this is a resource packet... send next packet
			if packet.type == .resource {
				if !packet.isFinal {
					sendResourcePacket(packet.resource!)
				} else {
					if let resource = packet.resource, let completionHandler = resource.onCompletion {
						completionHandler(true)
					}
				}
			}
		}
	}
	
	/**
	 This is for internal use only
	 **/
	public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
		if let packet = ALBPeerPacket(packetData: data) {
			processPacket(packet)
		} else {
			// store data from this read and append to it with data from next read
			if _cachedData == nil {
				_cachedData = Data()
			}
			
			_cachedData!.append(data)
			if _cachedData!.count > ALBPeerMaxDataSize * 4 {
				_socket.disconnect()
				return
			}
			
			if let packet = ALBPeerPacket(packetData: _cachedData!) {
				processPacket(packet)
			}
		}
		
		_socket.readData(to: ALBPeerPacketDelimiter, withTimeout: -1, tag: 0)
	}
	
	private func processPacket(_ packet: ALBPeerPacket) {
		_cachedData = nil
		
		switch packet.type {
		case .text:
			delegateQueue.async(execute: {[unowned self]() -> Void in
					if let delegate = self.delegate {
						delegate.textReceived(self, text: NSString(data: packet.data! as Data, encoding: String.Encoding.utf8.rawValue) as! String)
					} else {
						print("Connection delegate is not assigned")
					}
				})
		case .data:
			delegateQueue.async(execute: {[unowned self]() -> Void in
					if let delegate = self.delegate {
						delegate.dataReceived(self, data: packet.data! as Data)
					} else {
						print("Connection delegate is not assigned")
					}
				})
		case .resource:
			if let resourceID = packet.resource?.identity, let name = packet.resource?.name, let resourceLength = packet.resource?.length, let packetLength = packet.data?.count {
				let handle: FileHandle
				var resourcePath: String
				var resource = _resourceFiles[packet.resource!.identity]
				
				if let resource = resource {
					handle = resource.handle
					resourcePath = resource.path
				} else {
					// create file
					let searchPaths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
					let documentFolderPath = searchPaths[0]
					resourcePath = "\(documentFolderPath)/\(name)"
					var nameIndex = 1
					while FileManager.default.fileExists(atPath: resourcePath) {
						let parts = resourcePath.components(separatedBy: ".")
						resourcePath = ""
						if parts.count > 1 {
							let partCount = parts.count - 1
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
					
					FileManager.default.createFile(atPath: resourcePath, contents: nil, attributes: nil)
					if let fileHandle = FileHandle(forWritingAtPath: resourcePath) {
						resource = Resource(handle: fileHandle, path: resourcePath, name: name)
						let progress = Progress(totalUnitCount: Int64(resourceLength))
						resource?.progress = progress
						_resourceFiles[resourceID] = resource
						handle = fileHandle
					} else {
						resourceCopyError(resourceID, name: name)
						return
					}
					
					delegateQueue.async(execute: {[unowned self]() -> Void in
							if let delegate = self.delegate {
								delegate.startedReceivingResource(self, atURL: URL(fileURLWithPath: resourcePath), name: packet.resource!.name, resourceID: resourceID, progress: resource!.progress)
							} else {
								print("Connection delegate is not assigned")
							}
						})
				}
				
				if let progress = resource?.progress {
					progress.completedUnitCount = progress.completedUnitCount + packetLength
				}
				
				handle.write(packet.data! as Data)
				
				if packet.isFinal {
					handle.closeFile()
					let resource = _resourceFiles[resourceID]!
					_resourceFiles.removeValue(forKey: resourceID)
					delegateQueue.async(execute: {[unowned self]() -> Void in
							if let delegate = self.delegate {
								delegate.resourceReceived(self, atURL: URL(fileURLWithPath: resourcePath), name: resource.name, resourceID: resourceID)
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
			if let resource = packet.resource, let completionHandler = resource.onCompletion {
				completionHandler(false)
			}
		default:
			// other cases handled elsewhere
			break
		}
	}
	
	private func resourceCopyError(_ resourceID: String, name: String) {
		let resource = ALBPeerResource(identity: resourceID, name: name)
		var packet = ALBPeerPacket(type: .resourceError)
		packet.resource = resource
		
		_socket.write(packet.packetDataUsingData(nil), withTimeout: ALBPeerWriteTimeout, tag: 0)
	}
	
	/**
	 This is for internal use only
	 **/
	public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
		delegateQueue.async(execute: {[unowned self]() -> Void in
				if let delegate = self.delegate {
					delegate.disconnected(self, byRequest: self._disconnecting)
				} else {
					print("Connection delegate is not assigned")
				}
			})
	}
}
