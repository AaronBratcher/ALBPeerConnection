//
//  ALBPeer.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 4/3/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

class ALBPeer {
	var name: String
	var peerID: String
	var service: NetService?

	func dataValue() -> Data {
		let dict: [String: AnyObject] = ["name": name as AnyObject, "peerID": peerID as AnyObject]
		let dictData = NSKeyedArchiver.archivedData(withRootObject: dict)
		return dictData
	}

	init?(dataValue: Data) {
		if let dataDict = NSKeyedUnarchiver.unarchiveObject(with: dataValue) as? [String: AnyObject] {
			name = dataDict["name"] as! String
			peerID = dataDict["peerID"] as! String
		} else {
			return nil
		}
	}

	init(name: String, peerID: String) {
		self.name = name
		self.peerID = peerID
	}
}
