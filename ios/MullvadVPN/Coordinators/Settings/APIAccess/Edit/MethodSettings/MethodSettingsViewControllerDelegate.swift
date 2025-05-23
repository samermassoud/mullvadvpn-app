//
//  MethodSettingsViewControllerDelegate.swift
//  MullvadVPN
//
//  Created by pronebird on 23/11/2023.
//  Copyright © 2025 Mullvad VPN AB. All rights reserved.
//

import Foundation

protocol MethodSettingsViewControllerDelegate: AnyObject, AccessMethodEditing {
    func controllerShouldShowProtocolPicker(_ controller: MethodSettingsViewController)
    func controllerShouldShowShadowsocksCipherPicker(_ controller: MethodSettingsViewController)
}
