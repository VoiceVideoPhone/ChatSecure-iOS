//
//  OMEMODeviceFingerprintCell.swift
//  ChatSecure
//
//  Created by Chris Ballinger on 10/14/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import XLForm
import OTRAssets
import XMPPFramework
import FormatterKit

private extension String {
    //http://stackoverflow.com/a/34454633/805882
    func splitEvery(n: Int) -> [String] {
        var result: [String] = []
        let chars = Array(characters)
        for index in 0.stride(to: chars.count, by: n) {
            result.append(String(chars[index..<min(index+n, chars.count)]))
        }
        return result
    }
}

//private extension TTT

public extension XLFormBaseCell {
    
    public class func defaultRowDescriptorType() -> String {
        let type = NSStringFromClass(self)
        return type
    }
    
    public class func registerCellClass(forType: String) {
        let bundle = OTRAssets.resourcesBundle()
        let path = bundle.bundlePath
        let bundleName = (path as NSString).lastPathComponent
        let className = bundleName + "/" + NSStringFromClass(self)
        XLFormViewController.cellClassesForRowDescriptorTypes().setObject(className, forKey: forType)
    }
}

@objc(OMEMODeviceFingerprintCell)
public class OMEMODeviceFingerprintCell: XLFormBaseCell {
    
    @IBOutlet weak var fingerprintLabel: UILabel!
    @IBOutlet weak var trustSwitch: UISwitch!
    @IBOutlet weak var lastSeenLabel: UILabel!
    
    private static let intervalFormatter = TTTTimeIntervalFormatter()
    
    public override class func formDescriptorCellHeightForRowDescriptor(rowDescriptor: XLFormRowDescriptor!) -> CGFloat {
        return 90
    }
    
    public override func update() {
        super.update()
        guard let device = rowDescriptor.value as? OTROMEMODevice else {
            return
        }
        let trusted = device.isTrusted()
        trustSwitch.on = trusted
        
        // we've already filtered out devices w/o public keys
        // so publicIdentityKeyData should never be nil
        
        var fingerprintData = NSData()
        
        if (device.publicIdentityKeyData!.length == 32) {
            fingerprintData = device.publicIdentityKeyData!
        } else if (device.publicIdentityKeyData!.length == 33) {
            // why is there an extra 0x05 at the front?
            // maybe blame libsignal-protocol-c library
            fingerprintData = device.publicIdentityKeyData!.subdataWithRange(NSMakeRange(1, 32))
        }
        
        let fingerprint = fingerprintData.xmpp_hexStringValue().splitEvery(8).joinWithSeparator(" ")
        
        fingerprintLabel.text = fingerprint
        let interval = -NSDate().timeIntervalSinceDate(device.lastSeenDate)
        let since = self.dynamicType.intervalFormatter.stringForTimeInterval(interval)
        let lastSeen = NSLocalizedString("Last Seen: ", comment: "") + since
        lastSeenLabel.text = lastSeen
        let enabled = !rowDescriptor.isDisabled()
        trustSwitch.enabled = enabled
        fingerprintLabel.enabled = enabled
        lastSeenLabel.enabled = enabled
    }
    
    @IBAction func switchValueChanged(sender: UISwitch) {
        guard let device = rowDescriptor.value as? OTROMEMODevice else {
            return
        }
        if (trustSwitch.on) {
            device.trustLevel = .TrustedUser
        } else {
            device.trustLevel = .Untrusted
        }
        rowDescriptor.value = device
    }
    
}
