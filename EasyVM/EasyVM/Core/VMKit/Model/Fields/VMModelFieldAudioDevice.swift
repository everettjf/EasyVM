//
//  VMModelFieldAudioDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import Virtualization

struct VMModelFieldAudioDevice: Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case InputOutputStream, InputStream, OutputStream
        var id: Self { self }
    }
    let type: DeviceType
    
    var description: String {
        return "\(type)"
    }
    
    static func `default`() -> VMModelFieldAudioDevice {
        return VMModelFieldAudioDevice(type:.InputOutputStream)
    }
    
    func createConfiguration() -> VZAudioDeviceConfiguration {
        if type == .InputStream {
            let audioConfiguration = VZVirtioSoundDeviceConfiguration()
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            audioConfiguration.streams = [inputStream]
            return audioConfiguration
        }
        
        if type == .OutputStream {
            let audioConfiguration = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            audioConfiguration.streams = [outputStream]
            return audioConfiguration
        }
        
        let audioConfiguration = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfiguration.streams = [inputStream, outputStream]
        return audioConfiguration
    }
}
