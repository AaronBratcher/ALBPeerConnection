//
//  ALBPeerPacket.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 4/3/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

enum ALBPeerPacketType: String {
	case connectionRequest
	case connectionAccepted
	case connectionDenied
	case data
	case text
	case resource
	case resourceError
}

typealias completionHandler = (_ sent: Bool) -> ()

struct ALBPeerResource {
	var identity: String = ""
	var name: String = ""

	var url: URL?
	var onCompletion: completionHandler?
	var progress: Progress?
	var offset = 0
	var length = 0
	var mappedData: Data?

	init(identity: String, name: String) {
		self.identity = identity
		self.name = name
	}

	init(identity: String, name: String, url: URL, data: Data) {
		self.identity = identity
		self.name = name
		self.url = url
		self.mappedData = data

		length = data.count
	}

	func dictValue() -> [String: String] {
		return ["identity": identity, "name": name, "length": "\(length)"]
	}
}

struct ALBPeerPacket {
	var type: ALBPeerPacketType
	var isFinal = false
	var data: Data?
	var resource: ALBPeerResource?

	func packetDataUsingData(_ data: Data?) -> Data {
		var dict: [String: AnyObject] = ["type": type.rawValue as AnyObject]
		dict["isFinal"] = isFinal as AnyObject

		if let data = data {
			dict["data"] = data as AnyObject
		}
		if let resource = resource {
			dict["resource"] = resource.dictValue() as AnyObject
		}

		let dictData = NSKeyedArchiver.archivedData(withRootObject: dict)
		var packetData = NSData(data: dictData) as Data
		packetData.append(ALBPeerPacketDelimiter)

		return packetData
	}

	init?(packetData: Data) {
		let dataValue = Data(bytes: (packetData as NSData).bytes, count: packetData.count - 3)		
		if let dataDict = NSKeyedUnarchiver.unarchiveObject(with: dataValue) as? [String: AnyObject] {
			if let type = ALBPeerPacketType(rawValue: dataDict["type"] as! String) {
				self.type = type
			} else {
				return nil
			}

			if let data = dataDict["data"] as? Data {
				self.data = data
			}

			isFinal = dataDict["isFinal"] as! Bool

			if let resource = dataDict["resource"] as? [String: String] {
				self.resource = ALBPeerResource(identity: resource["identity"]!, name: resource["name"]!)
			}
		} else {
			return nil
		}
	}

	init(type: ALBPeerPacketType) {
		self.type = type
	}
}
