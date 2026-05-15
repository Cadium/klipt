//
//  KliptApp.swift
//  Klipt
//
//  Created by Olaoluwakitan Oguntowo on 15/05/2026.
//

import SwiftUI
import Photos

@main
struct KliptApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
                }
        }
    }
}
