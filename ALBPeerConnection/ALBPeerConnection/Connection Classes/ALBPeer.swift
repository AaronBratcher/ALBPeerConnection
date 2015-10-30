//
//  ALBPeer.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 4/3/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

class ALBPeer {
    var name:String
    var peerID:String
    var service:NSNetService?
    
    func dataValue() -> NSData {
        let dict:[String:AnyObject] = ["name":name,"peerID":peerID]
        let dictData = NSKeyedArchiver.archivedDataWithRootObject(dict)
        return dictData
    }
    
    init?(dataValue:NSData) {
        if let dataDict = NSKeyedUnarchiver.unarchiveObjectWithData(dataValue) as? [String:AnyObject] {
            name = dataDict["name"] as! String
            peerID = dataDict["peerID"] as! String
        } else {
            name = ""
            peerID = ""
            return nil
        }
    }
    
    init(name:String, peerID:String) {
        self.name = name
        self.peerID = peerID
    }
}
