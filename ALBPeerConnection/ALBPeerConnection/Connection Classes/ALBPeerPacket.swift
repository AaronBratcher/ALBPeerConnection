//
//  ALBPeerPacket.swift
//  ALBPeerConnection
//
//  Created by Aaron Bratcher on 4/3/15.
//  Copyright (c) 2015 Aaron Bratcher. All rights reserved.
//

import Foundation

enum ALBPeerPacketType:String {
    case connectionRequest = "connectionRequest"
    case connectionAccepted = "connectionAccepted"
    case connectionDenied = "connectionDenied"
    case data = "data"
	case text = "text"
    case resource = "resource"
    case resourceError = "resourceError"
}

typealias completionHandler = (sent:Bool)->()

struct ALBPeerResource {
    var identity:String = ""
    var name:String = ""
    
    var url:NSURL?
    var onCompletion:completionHandler?
    var progress:NSProgress?
    var offset = 0
    var length = 0
    var mappedData:NSData?
    
    init(identity:String, name:String) {
        self.identity = identity
        self.name = name
    }
    
    init(identity:String, name:String, url:NSURL, data:NSData) {
        self.identity = identity
        self.name = name
        self.url = url
        self.mappedData = data
        
        length = data.length
    }
    
    func dictValue() -> [String:String] {
        return ["identity":identity, "name":name, "length": "\(length)"]
    }
}

struct ALBPeerPacket {
    var type:ALBPeerPacketType
    var isFinal = false
    var data:NSData?
    var resource:ALBPeerResource?
    
    func packetDataUsingData(data:NSData?) -> NSData {
        var dict:[String:AnyObject] = ["type":type.rawValue]
        dict["isFinal"] = isFinal
        
        if let data = data {
            dict["data"] = data
        }
        if let resource = resource {
            dict["resource"] = resource.dictValue()
        }
        
        let dictData = NSKeyedArchiver.archivedDataWithRootObject(dict)
        var packetData = NSMutableData(data: dictData)
        packetData.appendBytes(ALBPeerPacketDelimiter.bytes, length: 3)
        
        return packetData
    }
    
    init?(packetData:NSData) {
        let dataValue = NSData(bytes: packetData.bytes, length: packetData.length-3)
        if let dataDict = NSKeyedUnarchiver.unarchiveObjectWithData(dataValue) as? [String:AnyObject] {
            if let type = ALBPeerPacketType(rawValue: dataDict["type"] as! String) {
                self.type = type
            } else {
                return nil
            }
            
            if let data = dataDict["data"] as? NSData {
                self.data = data
            }
            
            isFinal = dataDict["isFinal"] as! Bool
            
            if let resource = dataDict["resource"] as? [String:String] {
                self.resource = ALBPeerResource(identity: resource["identity"]!, name: resource["name"]!)
            }
        } else {
            return nil
        }
    }
    
    init(type:ALBPeerPacketType) {
        self.type = type
    }
}