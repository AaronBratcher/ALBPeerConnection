//
//  SyncEngine.swift
//  Shopping
//
//  Created by Aaron Bratcher on 3/22/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation
import ALBNoSQLDB
import ALBPeerConnection

let kSyncComplete = "SyncComplete"
let kDevicesTable = "Devices"
let kMonthlySummaryEntriesTable = "SummaryEntries"

typealias DeviceResponse = (_ allow: Bool) -> ()
protocol SyncEngineLinkDelegate {
	func linkRequested(_ device: SyncDevice, deviceResponse: @escaping DeviceResponse)
	func linkDenied(_ device: SyncDevice)
}

protocol SyncEngineDelegate {
	func statusChanged(_ device: SyncDevice)

	func syncDeviceFound(_ device: SyncDevice)
	func syncDeviceLost(_ device: SyncDevice)
}

enum SyncDeviceStatus {
	case idle, linking, unlinking, syncing
}

enum DataType: Int {
	case syncLogRequest = 1
	case syncError = 2
	case unlink = 3
}

class SyncDevice: ALBNoSQLDBObject {
	var name = ""
	var linked = false
	var lastSync: Date?
	var lastSequence = 0
	var status = SyncDeviceStatus.idle
	var errorState = false
	var netNode: ALBPeer?

	convenience init?(key: String) {
		if let value = ALBNoSQLDB.dictValueForKey(table: kDevicesTable, key: key) {
			self.init(keyValue: key, dictValue: value)
		} else {
			return nil
		}
	}

	override init(keyValue: String, dictValue: [String: AnyObject]? = nil) {
		if let dictValue = dictValue {
			if let name = dictValue["name"] as? String {
				self.name = name
			}
			
			if let linked = dictValue["linked"] as? Bool {
				self.linked = linked
			}
			
			if let lastSequence = dictValue["lastSequence"] as? Int {
				self.lastSequence = lastSequence
			}
			
			if let lastSync = dictValue["lastSync"] as? String {
				self.lastSync = ALBNoSQLDB.dateValueForString(lastSync)
			}
		}

		super.init(keyValue: keyValue, dictValue: dictValue)
	}

	func save() {
		let _ = ALBNoSQLDB.setValue(table: kDevicesTable, key: key, value: jsonValue(), autoDeleteAfter: nil)
	}

	override func dictionaryValue() -> [String: AnyObject] {
		var dictValue = [String: AnyObject]()

		dictValue["name"] = name as AnyObject
		dictValue["linked"] = linked as AnyObject
		dictValue["lastSequence"] = lastSequence as AnyObject
		if let lastSync = self.lastSync {
			dictValue["lastSync"] = ALBNoSQLDB.stringValueForDate(lastSync) as AnyObject
		}

		return dictValue
	}
}

class SyncEngine: ALBPeerServerDelegate, ALBPeerClientDelegate, ALBPeerConnectionDelegate {
	var delegate: SyncEngineDelegate? {
		didSet {
			for device in nearbyDevices {
				delegate?.syncDeviceFound(device)
			}
		}
	}

	var linkDelegate: SyncEngineLinkDelegate?

	var nearbyDevices = [SyncDevice]()
	var offlineDevices = [SyncDevice]()

	private var _netServer: ALBPeerServer
	private var _netClient: ALBPeerClient
	private var _netConnections = [ALBPeerConnection]()
	private let syncQueue = DispatchQueue(label: "com.AaronLBratcher.SyncQueue")
	private var _timer: DispatchSourceTimer
	private var _identityKey = ""

	init?(name: String) {
		if let deviceKeys = ALBNoSQLDB.keysInTable(kDevicesTable, sortOrder: "name") {
			for deviceKey in deviceKeys {
				if let offlineDevice = SyncDevice(key: deviceKey) {
					offlineDevices.append(offlineDevice)
				}
			}
		}

		_timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: UInt(0)), queue: syncQueue) /*Migrator FIXME: Use DispatchSourceTimer to avoid the cast*/ as! DispatchSource

		let _ = ALBNoSQLDB.enableSyncing()
		if let dbKey = ALBNoSQLDB.dbInstanceKey() {
			_identityKey = dbKey
		}

		let netNode = ALBPeer(name: name, peerID: _identityKey)
		_netServer = ALBPeerServer(serviceType: "_mymoneysync._tcp.", serverNode: netNode, serverDelegate: nil)
		_netClient = ALBPeerClient(serviceType: "_mymoneysync._tcp.", clientNode: netNode, clientDelegate: nil)
		_netServer.delegate = self

		// this is here instead of above because all stored properties of a class must be populated first
		if _identityKey == "" {
			return nil
		}

		if !_netServer.startPublishing() {
			return nil
		}

		_netClient.delegate = self
		_netClient.startBrowsing()

		// auto-sync with linked nearby devices every minute
		_timer.scheduleRepeating(deadline: .now(), interval: .milliseconds(60000), leeway: .milliseconds(1000))
		_timer.setEventHandler {
			self.syncAllDevices()
		}
		_timer.resume()

		return
	}

	func stopBonjour() {
		_netServer.stopPublishing()
		_netClient.stopBrowsing()
	}

	func startBonjour() {
		let _ = _netServer.startPublishing()
		_netClient.startBrowsing()
	}

	func linkDevice(_ device: SyncDevice) {
		device.status = .linking
		_netClient.connectToServer(device.netNode!)
		notifyStatusChanged(device)
	}

	func forgetDevice(_ device: SyncDevice) {
		if nearbyDevices.filter({ $0.key == device.key }).count > 0 {
			device.status = .unlinking
			_netClient.connectToServer(device.netNode!)
			notifyStatusChanged(device)
		}

		completeDeviceUnlink(device)
	}

	func completeDeviceUnlink(_ device: SyncDevice) {
		let _ = ALBNoSQLDB.deleteForKey(table: kDevicesTable, key: device.key)
		device.linked = false
		if offlineDevices.filter({ $0.key == device.key }).count > 0 {
			offlineDevices = offlineDevices.filter({ $0.key != device.key })
		}

		notifyStatusChanged(device)
	}

	private func deviceForNode(_ node: ALBPeer) -> SyncDevice {
		let devices = nearbyDevices.filter({ $0.key == node.peerID })
		if devices.count > 0 {
			return devices[0]
		}

		let syncDevice: SyncDevice
		if let device = SyncDevice(key: node.peerID) {
			syncDevice = device
		} else {
			let device = SyncDevice()
			device.key = node.peerID
			device.name = node.name

			syncDevice = device
		}
		syncDevice.netNode = node

		return syncDevice
	}

	func syncAllDevices() {
		for device in nearbyDevices {
			syncWithDevice(device)
		}
	}

	func syncWithDevice(_ device: SyncDevice) {
		if !device.linked || device.status != .idle {
			return
		}

		device.status = .syncing
		notifyStatusChanged(device)
		_netClient.connectToServer(device.netNode!)
	}

	private func notifyStatusChanged(_ device: SyncDevice) {
		DispatchQueue.main.async(execute: { () -> Void in
			self.delegate?.statusChanged(device)
		})
	}

	// MARK: - Server delegate calls
	func serverPublishingError(_ errorDict: [NSObject: AnyObject]) {
		print("publishing error: \(errorDict)")
	}

	/**
	Called when a connection is requested.
	
	- parameter remoteNode: An ALBPeer object initialized with a name and a unique identifier.
	- parameter requestResponse: A closure that is to be called with a Bool indicating whether to allow the connection or not. This can be done asynchronously so a dialog can be invoked, etc.
	*/
	func allowConnectionRequest(_ remoteNode: ALBPeer, requestResponse: @escaping (_ allow: Bool) -> ()) {
		let device = deviceForNode(remoteNode)
		if device.linked {
			requestResponse(true)
		} else {
			if let linkDelegate = linkDelegate {
				linkDelegate.linkRequested(device, deviceResponse: { (allow) -> () in
					requestResponse(allow)
				})
			} else {
				requestResponse(false)
			}
		}
	}

	func clientDidConnect(_ connection: ALBPeerConnection) {
		// connection delegate must be made to get read and write calls
		connection.delegate = self

		// strong reference must be kept of the connection
		_netConnections.append(connection)

		// client connected to link or sync. if connection was allowed, we're now linked.
		let device = deviceForNode(connection.remotNode)
		if !device.linked {
			device.linked = true
			device.save()
		}

		device.status = .idle
	}

	// MARK: - Client delegate calls
	func clientBrowsingError(_ errorDict: [NSObject: AnyObject]) {
		print("browsing error: \(errorDict)")
	}

	func serverFound(_ server: ALBPeer) {
		syncQueue.sync(execute: { () -> Void in
			let device = self.deviceForNode(server)
			if self.nearbyDevices.filter({ $0.key == device.key }).count > 0 || device.key == self._identityKey {
				return
			}

			self.nearbyDevices.append(device)
			self.offlineDevices = self.offlineDevices.filter({ $0.key != device.key })
			self.syncWithDevice(device)

			DispatchQueue.main.async(execute: { () -> Void in
				self.delegate?.syncDeviceFound(device)
			})
		})
	}

	func serverLost(_ server: ALBPeer) {
		syncQueue.sync(execute: { () -> Void in
			let device = self.deviceForNode(server)
			if device.status != .idle {
				return
			}

			self.nearbyDevices = self.nearbyDevices.filter({ $0.key != device.key })
			if let offlineDevice = SyncDevice(key: device.key) {
				self.offlineDevices.append(offlineDevice)
			}

			DispatchQueue.main.async(execute: { () -> Void in
				self.delegate?.syncDeviceLost(device)
			})
		})
	}

	func unableToConnect(_ server: ALBPeer) {
		let device = deviceForNode(server)

		switch device.status {
		case .linking:
			device.errorState = true
		case .syncing:
			device.errorState = true
		default:
			break
		}

		device.status = .idle
		notifyStatusChanged(device)
	}

	func connectionDenied(_ server: ALBPeer) {
		let device = deviceForNode(server)
		device.errorState = false
		device.status = .idle
		notifyStatusChanged(device)
		linkDelegate?.linkDenied(device)
	}

	func connected(_ connection: ALBPeerConnection) {
		// connection delegate must be made to get read and write calls
		connection.delegate = self

		// strong reference must be kept of the connection
		_netConnections.append(connection)

		let device = deviceForNode(connection.remotNode)

		// connection was initiatied to link, unlink or sync. An allowed connection says we should now be linked.
		if !device.linked {
			device.linked = true
			device.save()
			device.errorState = false
		}

		if device.status == .unlinking {
			let dict = ["dataType": DataType.unlink.rawValue]
			let data = NSKeyedArchiver.archivedData(withRootObject: dict)
			connection.sendData(data)
			connection.disconnect()

			let _ = ALBNoSQLDB.deleteForKey(table: kDevicesTable, key: device.key)
			device.linked = false
			device.status = .idle
			notifyStatusChanged(device)
		} else {
			let dict = ["dataType": DataType.syncLogRequest.rawValue, "lastSequence": device.lastSequence]
			let data = NSKeyedArchiver.archivedData(withRootObject: dict)
			connection.sendData(data)
		}
	}

	// MARK: - Connection delegate calls
	func disconnected(_ connection: ALBPeerConnection, byRequest: Bool) {
		let device = deviceForNode(connection.remotNode)

		if !byRequest {
			switch device.status {
			case .linking:
				device.errorState = true
			case .syncing:
				device.errorState = true
			default:
				break
			}

			device.status = .idle
			notifyStatusChanged(device)
		}

		_netConnections = _netConnections.filter({ $0 != connection })
	}

	func textReceived(_ connection: ALBPeerConnection, text: String) {
		// not used
	}

	func dataReceived(_ connection: ALBPeerConnection, data: Data) {
		let device = deviceForNode(connection.remotNode)
		// data packet is only sent to ask for sync file giving lastSequence or failure status of sync request

		if let dataDict = NSKeyedUnarchiver.unarchiveObject(with: data) as? [String: Int], let dataType = DataType(rawValue: dataDict["dataType"]!) {
			switch dataType {
			case .syncLogRequest: // server gets this
				let lastSequence = dataDict["lastSequence"]!

				syncQueue.async(execute: { () -> Void in
					let searchPaths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
					let documentFolderPath = searchPaths[0]
					let fileName = ALBNoSQLDB.guid()
					let logFilePath = "\(documentFolderPath)/\(fileName).txt"
					let url = URL(fileURLWithPath: logFilePath)

					let (success, _): (Bool, Int) = ALBNoSQLDB.createSyncFileAtURL(url, lastSequence: lastSequence, targetDBInstanceKey: connection.remotNode.peerID)

					if success, let zipURL = URL(string: "") {
						let progress = connection.sendResourceAtURL(zipURL, name: "\(fileName).zip", resourceID: fileName, onCompletion: { (sent) -> () in
							connection.disconnect()
							do {
								try FileManager.default.removeItem(at: zipURL)
							} catch _ {
							}

							device.errorState = !sent
							device.status = .idle
							self.notifyStatusChanged(device)
						})
					} else {
						// send sync error message
						let dict = ["dataType": DataType.syncError.rawValue]
						let data = NSKeyedArchiver.archivedData(withRootObject: dict)
						connection.sendData(data)
						connection.disconnect()
					}
				})

			case .unlink:
				completeDeviceUnlink(device)

			default: // client side gets this
				device.errorState = true
				device.status = .idle
				notifyStatusChanged(device)
			}
		} else { // could not parse data packet so don't know message... close connection
			connection.disconnect()
		}
	}

	func startedReceivingResource(_ connection: ALBPeerConnection, atURL: URL, name: String, resourceID: String, progress: Progress) {
		print("started to receive \(atURL)")
	}

	func resourceReceived(_ connection: ALBPeerConnection, atURL: URL, name: String, resourceID: String) {
		let device = deviceForNode(connection.remotNode)
		connection.disconnect()

		syncQueue.async(execute: { () -> Void in
			if let summaryKeys = ALBNoSQLDB.keysInTable(kMonthlySummaryEntriesTable, sortOrder: nil) {
				for key in summaryKeys {
					let _ = ALBNoSQLDB.deleteForKey(table: kMonthlySummaryEntriesTable, key: key)
				}
			}

			let logURL = URL(fileReferenceLiteralResourceName: "")

			let (successful, _, lastSequence): (Bool, String, Int) = ALBNoSQLDB.processSyncFileAtURL(logURL, syncProgress: nil)
			if successful {
				device.lastSequence = lastSequence
				device.lastSync = Date()
				device.save()
				device.errorState = false
			} else {
				device.errorState = true
			}

			do {
				try FileManager.default.removeItem(at: logURL)
			} catch _ {
			}

			device.status = .idle
			self.notifyStatusChanged(device)

			NotificationCenter.default.post(name: Notification.Name(rawValue: kSyncComplete), object: nil)
		})
	}

}
