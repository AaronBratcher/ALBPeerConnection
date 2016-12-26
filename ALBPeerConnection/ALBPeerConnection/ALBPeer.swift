//
//  ALBPeer.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 4/3/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

public final class ALBPeer {
	public var name: String
	public var peerID: String
	public var service: NetService?

	public func dataValue() -> Data {
		let dict: [String: AnyObject] = ["name": name as AnyObject, "peerID": peerID as AnyObject]
		let dictData = NSKeyedArchiver.archivedData(withRootObject: dict)
		return dictData
	}

	public init?(dataValue: Data) {
		if let dataDict = NSKeyedUnarchiver.unarchiveObject(with: dataValue) as? [String: AnyObject] {
			name = dataDict["name"] as! String
			peerID = dataDict["peerID"] as! String
		} else {
			return nil
		}
	}

	public init(name: String, peerID: String) {
		self.name = name
		self.peerID = peerID
	}
}
